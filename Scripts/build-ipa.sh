#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
project="$PWD"
app="$project/build/iphoneos/HiloCompanion.app"
mkdir -p build dist

xcrun swiftc HiloCompanion/HiloProtocol.swift HiloCompanion/HistoryStore.swift Tests/ProtocolChecks.swift -o build/protocol-checks
build/protocol-checks

xcodebuild -project HiloCompanion.xcodeproj -target HiloCompanion \
    -configuration Release -sdk iphoneos \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 \
    OBJROOT="$project/build/device-obj" CONFIGURATION_BUILD_DIR="$project/build/iphoneos" build

plutil -lint "$app/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist")
ipa="$project/dist/Hilo-Companion-$version-unsigned.ipa"
test "$(xcrun lipo -archs "$app/HiloCompanion")" = arm64
xcrun vtool -show-build "$app/HiloCompanion" | grep -E 'platform +IOS$'

stage=$(mktemp -d "$project/build/ipa.XXXXXX")
trap 'rm -r -- "$stage"' EXIT
mkdir "$stage/Payload"
ditto "$app" "$stage/Payload/HiloCompanion.app"
test ! -e "$ipa" || rm -- "$ipa"
(cd "$stage" && zip -qr "$ipa" Payload)
unzip -tq "$ipa"
shasum -a 256 "$ipa"
