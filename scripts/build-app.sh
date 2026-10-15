#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The desktop client requires macOS.\n' >&2
    exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --dev ) ]]; then
    printf 'Usage: scripts/build-app.sh [--dev]\n' >&2
    exit 2
fi
if [[ "${1:-}" == --dev ]]; then
    app_name="Transcriber Dev"
    info_plist=Resources/Info-Dev.plist
else
    app_name=Transcriber
    info_plist=Resources/Info.plist
fi
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
build_jobs="${TRANSCRIBER_BUILD_JOBS:-8}"
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)
swift_flags=(--scratch-path .build/client-swift -c release --jobs "$build_jobs" --product Transcriber
    --force-resolved-versions
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$macos_sdk")
swift build "${swift_flags[@]}"
swift_bin=$(swift build "${swift_flags[@]}" --show-bin-path)

app_path="$project_dir/build/$app_name.app"
mkdir -p build
staging_dir=$(mktemp -d "$project_dir/build/.app.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/$app_name.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$swift_bin/Transcriber" "$staged_app/Contents/MacOS/Transcriber"
cp "$info_plist" "$staged_app/Contents/Info.plist"
cp Resources/swift-openapi-runtime-LICENSE.txt Resources/swift-http-types-LICENSE.txt \
    THIRD_PARTY_NOTICES.md "$staged_app/Contents/Resources/"
swift scripts/make-icon.swift "$project_dir/.build/Transcriber.iconset"
iconutil -c icns .build/Transcriber.iconset -o "$staged_app/Contents/Resources/Transcriber.icns"

signing_identity="${TRANSCRIBER_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    identities=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
    identity_count=$(printf '%s\n' "$identities" | awk 'NF {n++} END {print n+0}')
    if [[ "$identity_count" == 1 ]]; then signing_identity="$identities"; else signing_identity=-; fi
fi
codesign --force --sign "$signing_identity" --options runtime \
    --entitlements Resources/Transcriber.entitlements --identifier "$bundle_id" "$staged_app"
codesign --verify --deep --strict "$staged_app"
if [[ -d "$app_path" ]]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
    if [[ "$existing_id" != "$bundle_id" ]]; then
        printf 'Another app occupies %s; leaving it untouched.\n' "$app_path" >&2
        exit 1
    fi
    rm -rf "$app_path"
fi
mv "$staged_app" "$app_path"
printf '\nBuilt %s\n' "$app_path"
