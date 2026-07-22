#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
app_dir="$repo_root/dist/AnnoyO.app"
release_dir="${ANNOYO_RELEASE_DIR:-$repo_root/release}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Packaging/Info.plist")"
expected_tag="v${version}"
release_tag="${1:-$expected_tag}"

if [[ "$release_tag" != "$expected_tag" ]]; then
    print -u2 -- "Release tag $release_tag does not match app version $version (expected $expected_tag)."
    exit 1
fi

if [[ ! -d "$app_dir" ]]; then
    print -u2 -- "Missing $app_dir. Run ./scripts/build-app.sh first."
    exit 1
fi

/usr/bin/codesign --verify --deep --strict=all --verbose=4 "$app_dir"

archive_name="AnnoyO-${release_tag}-macOS.zip"
checksum_name="${archive_name}.sha256"
archive_path="$release_dir/$archive_name"
checksum_path="$release_dir/$checksum_name"

/bin/mkdir -p "$release_dir"
/bin/rm -f "$archive_path" "$checksum_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"

verification_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/annoyo-release.XXXXXX")"
cleanup() {
    /bin/rm -rf "$verification_dir"
}
trap cleanup EXIT

/usr/bin/ditto -x -k "$archive_path" "$verification_dir"
/usr/bin/codesign --verify --deep --strict=all --verbose=4 "$verification_dir/AnnoyO.app"

(
    cd "$release_dir"
    /usr/bin/shasum -a 256 "$archive_name" > "$checksum_name"
)

print -- "$archive_path"
print -- "$checksum_path"
