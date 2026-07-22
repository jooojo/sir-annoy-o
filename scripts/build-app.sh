#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
app_dir="$repo_root/dist/AnnoyO.app"
contents_dir="$app_dir/Contents"
sdk_path="${ANNOYO_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"

cd "$repo_root"
SDKROOT="$sdk_path" \
CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/swiftpm-cache" \
swift build -c release

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp ".build/release/AnnoyO" "$contents_dir/MacOS/AnnoyO"
cp "Packaging/Info.plist" "$contents_dir/Info.plist"

SDKROOT="$sdk_path" \
CLANG_MODULE_CACHE_PATH="$repo_root/.build/icon-cache" \
swiftc \
    -parse-as-library \
    -sdk "$sdk_path" \
    Packaging/IconGenerator.swift \
    -o .build/annoyo-icon-generator
.build/annoyo-icon-generator .build/AppIcon.iconset
if ! iconutil --convert icns --output "$contents_dir/Resources/AppIcon.icns" .build/AppIcon.iconset 2>/dev/null; then
    icon_tiff_dir="$repo_root/.build/AppIcon.tiffset"
    mkdir -p "$icon_tiff_dir"
    icon_tiffs=()
    for icon_name in \
        icon_16x16.png \
        icon_32x32.png \
        icon_128x128.png \
        icon_256x256.png \
        icon_512x512.png \
        icon_512x512@2x.png; do
        icon_tiff="$icon_tiff_dir/${icon_name:r}.tiff"
        sips -s format tiff ".build/AppIcon.iconset/$icon_name" --out "$icon_tiff" >/dev/null
        icon_tiffs+=("$icon_tiff")
    done
    tiffutil -catnosizecheck "${icon_tiffs[@]}" -out .build/AppIcon.tiff >/dev/null
    tiff2icns .build/AppIcon.tiff "$contents_dir/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$app_dir"

signature_error=""
successful_verifications=0
for attempt in {1..40}; do
    if signature_error="$(codesign --verify --deep --strict=all --verbose=4 "$app_dir" 2>&1)"; then
        (( successful_verifications += 1 ))
        if (( successful_verifications == 3 )); then
            break
        fi
    else
        successful_verifications=0
    fi
    if (( attempt == 40 )); then
        print -u2 -- "$signature_error"
        exit 1
    fi
    sleep 0.25
done

echo "$app_dir"
