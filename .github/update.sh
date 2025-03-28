#!/bin/sh

ci=false
if echo "$@" | grep -qoE '(--ci)'; then
    ci=true
fi

only_check=false
if echo "$@" | grep -qoE '(--only-check)'; then
    only_check=true
fi

repo_tags=$(curl 'https://api.github.com/repos/zen-browser/desktop/tags' -s)

twilight_tag=$(echo "$repo_tags" | jq -r '.[]|select(.name|test("twilight"))')

twilight_version_name=$(curl 'https://api.github.com/repos/zen-browser/desktop/releases/tags/twilight' -s | jq -r '.name' | grep -oE '([0-9\.])+(t|-t.[0-9]+)')
if [ "$twilight_version_name" = "" ]; then
    echo "No twilight version could be extracted..."
    exit 1
fi

beta_tag=$(echo "$repo_tags" | jq -r '(map(select(.name | test("[0-9]+\\.[0-9]+b$")))) | first')

commit_beta_targets=""
commit_beta_version=""
commit_twilight_targets=""
commit_twilight_version=""

get_twilight_release_from_zen_repo() {
    arch=$1

    curl -sL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://api.github.com/repos/zen-browser/desktop/releases/tags/twilight |
        jq -r --arg arch "$arch" '.assets[] | select(.name | contains("zen.linux") and contains($arch)) | "\(.id) \(.name)"'
}

download_artifact_from_zen_repo() {
    artifact_id="$1"
    # relative or absolute path, whatever
    file_path="$2"

    curl -L \
        -H "Accept: application/octet-stream" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/zen-browser/desktop/releases/assets/$artifact_id" >"$file_path"
}

try_to_update() {
    # Options like "beta" or "twilight"
    version_name=$1
    # Options like "x86_64" or "aarch64"
    arch=$2
    # JSON object with metadata about the specified version($1)
    target_tag_meta=$3

    meta=$(jq ".[\"$version_name\"][\"$arch-linux\"]" <sources.json)
    local_sha1=$(echo "$meta" | jq -r '.sha1')
    remote_sha1=$(echo "$target_tag_meta" | jq -r '.commit.sha')

    if [ "$version_name" = "twilight" ]; then
        release_url="https://github.com/zen-browser/desktop/releases/download/twilight/zen.linux-${arch}.tar.xz"

        prefetch_output=$(nix store prefetch-file --unpack --hash-type sha256 --json "$release_url")
        remote_sha256=$(echo "$prefetch_output" | jq -r '.hash')

        local_sha256=$(jq -r ".[\"$version_name\"][\"${arch}-linux\"].sha256" < sources.json)

        echo "Checking $version_name version @ $arch... local=$local_sha256 remote=$remote_sha256"

        if [ "$remote_sha256" = "$local_sha256" ]; then
            echo "Assets for twilight ${arch} are up to date"
            return
        fi

        echo "SHA256 changed for twilight ${arch} ($local_sha256 -> $remote_sha256)"
    else
        echo "Checking $version_name version @ $arch... local=$local_sha1 remote=$remote_sha1"

        if [ "$local_sha1" = "$remote_sha1" ]; then
            echo "Local $version_name version is up to date"
            return
        fi

        echo "Local $version_name version mismatch with remote so we* assume it's outdated"
    fi

    if $only_check; then
        echo "should_update=true" >>"$GITHUB_OUTPUT"
        exit 0
    fi

    version=$(echo "$target_tag_meta" | jq -r '.name')
    download_url="https://github.com/zen-browser/desktop/releases/download/$version/zen.linux-$arch.tar.xz"

    if [ -n "$remote_sha256" ]; then
        sha256="$remote_sha256"
    else
        prefetch_output=$(nix store prefetch-file --unpack --hash-type sha256 --json "$download_url")
        sha256=$(echo "$prefetch_output" | jq -r '.hash')
    fi

    semver=$version
    if [ "$version_name" = "twilight" ]; then
        semver="$twilight_version_name"

        short_sha1="$(echo "$remote_sha1" | cut -c1-7)"

        current_datetime=$(date +%Y%m%d%H)
        release_name="$version-$current_datetime"

        flake_repo_location="muratoffalex/zen-browser-flake"

        if ! gh release list | grep "$release_name" >/dev/null; then
            echo "Creating $release_name release..."

            # Users with push access to the repository can create a release.
            gh release --repo="$flake_repo_location" \
                create "$release_name" --notes "$semver#$remote_sha1 (for resilient)"
        else
            echo "Release $release_name already exists, skipping creation..."
        fi

        get_twilight_release_from_zen_repo "$arch" |
            while read -r line; do
                artifact_id=$(echo "$line" | cut -d' ' -f1)
                artifact_name=$(echo "$line" | cut -d' ' -f2)

                self_download_url="https://github.com/muratoffalex/zen-browser-flake/releases/download/$release_name/zen.linux-$arch.tar.xz"

                if ! gh release --repo="$flake_repo_location" view "$release_name" | grep "$artifact_name" >/dev/null; then
                    echo "[downloading] An artifact $artifact_name doesn't exists in $release_name"

                    download_artifact_from_zen_repo "$artifact_id" "/tmp/$artifact_name"

                    gh release --repo="$flake_repo_location" \
                        upload "$release_name" "/tmp/$artifact_name"

                    echo "[uploaded] The artifact is available @ following link: $self_download_url"
                else
                    echo "[skipping] An artifact $artifact_name already exists in $release_name @ following link: $self_download_url"
                fi

                jq ".[\"twilight\"][\"$arch-linux\"] = {\"version\":\"$semver\",\"sha1\":\"$remote_sha1\",\"url\":\"$self_download_url\",\"sha256\":\"$sha256\"}" <sources.json >sources.json.tmp
                mv sources.json.tmp sources.json
            done
    fi

    jq ".[\"$version_name\"][\"$arch-linux\"] = {\"version\":\"$semver\",\"sha1\":\"$remote_sha1\",\"url\":\"$download_url\",\"sha256\":\"$sha256\"}" <sources.json >sources.json.tmp
    mv sources.json.tmp sources.json

    echo "$version_name was updated to $semver"

    if ! $ci; then
        return
    fi

    if [ "$version_name" = "beta" ]; then
        if [ "$commit_beta_targets" = "" ]; then
            commit_beta_targets="$arch"
            commit_beta_version="$version"
        else
            commit_beta_targets="$commit_beta_targets && $arch"
        fi
    fi

    if [ "$version_name" = "twilight" ]; then
        if [ "$commit_twilight_targets" = "" ]; then
            commit_twilight_targets="$arch"
            commit_twilight_version="$twilight_version_name#$(echo "$remote_sha1" | cut -c1-7)"
        else
            commit_twilight_targets="$commit_twilight_targets && $arch"
        fi

    fi
}

set -e

try_to_update "beta" "x86_64" "$beta_tag"
try_to_update "beta" "aarch64" "$beta_tag"
try_to_update "twilight" "x86_64" "$twilight_tag"
try_to_update "twilight" "aarch64" "$twilight_tag"

if $only_check && $ci; then
    echo "should_update=false" >>"$GITHUB_OUTPUT"
fi

# Check if there are changes
if ! git diff --exit-code >/dev/null; then
    init_message="Update Zen Browser"
    message="$init_message"

    if [ "$commit_beta_targets" != "" ]; then
        message="$message beta @ $commit_beta_targets to $commit_beta_version"
    fi

    if [ "$commit_twilight_targets" != "" ]; then
        if [ "$message" != "$init_message" ]; then
            message="$message and"
        fi

        message="$message twilight @ $commit_twilight_targets to $commit_twilight_version"
    fi

    echo "commit_message=$message" >>"$GITHUB_OUTPUT"
fi
