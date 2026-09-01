#!/bin/bash
# Build an arm64 MeetMemo.app with the already-installed Xcode Command Line Tools.
#
# This intentionally avoids xcodebuild, the Mac App Store, Apple-account authentication,
# and all network access. The sherpa-onnx/ONNX Runtime dependencies must already exist in
# ./Frameworks (run fetch_sherpa_frameworks.sh separately when downloads are permitted).

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DIST_ROOT="${REPO_ROOT}/dist/local-clt"
readonly APP_NAME="MeetMemo"
readonly APP_BUNDLE="${APP_NAME}.app"
readonly BUNDLE_IDENTIFIER="com.youcai.meetmemo"
readonly ONNXRUNTIME_VERSION="1.24.4"
readonly ONNXRUNTIME_NAME="libonnxruntime.${ONNXRUNTIME_VERSION}.dylib"
readonly SHERPA_LIBRARY="${REPO_ROOT}/Frameworks/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a"
readonly SHERPA_HEADERS="${REPO_ROOT}/Frameworks/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers"
readonly BRIDGING_HEADER="${REPO_ROOT}/Frameworks/swift-wrapper/SherpaOnnx-Bridging-Header.h"
readonly ONNXRUNTIME_SOURCE="${REPO_ROOT}/Frameworks/onnxruntime/lib/${ONNXRUNTIME_NAME}"
readonly SOURCE_ENTITLEMENTS="${REPO_ROOT}/MeetMemo/MeetMemo.entitlements"

die() {
    echo "❌ $*" >&2
    exit 1
}

for tool in swiftc codesign iconutil plutil ditto file otool; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required local tool: ${tool}"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "Missing /usr/libexec/PlistBuddy"
[[ -f "$SHERPA_LIBRARY" ]] || die "Missing ${SHERPA_LIBRARY}. Fetch the pinned frameworks first."
[[ -d "$SHERPA_HEADERS" ]] || die "Missing sherpa-onnx headers: ${SHERPA_HEADERS}"
[[ -f "$BRIDGING_HEADER" ]] || die "Missing bridging header: ${BRIDGING_HEADER}"
[[ -f "$ONNXRUNTIME_SOURCE" ]] || die "Missing ${ONNXRUNTIME_SOURCE}"

mkdir -p "${REPO_ROOT}/dist"
STAGING_ROOT="$(mktemp -d "${REPO_ROOT}/dist/.local-clt-staging.XXXXXX")"
MODULE_CACHE="$(mktemp -d "${TMPDIR:-/private/tmp}/meetmemo-clt-module-cache.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT" "$MODULE_CACHE"' EXIT

APP_PATH="${STAGING_ROOT}/${APP_BUNDLE}"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
FRAMEWORKS_PATH="${CONTENTS_PATH}/Frameworks"
RESOURCES_PATH="${CONTENTS_PATH}/Resources"
mkdir -p "$MACOS_PATH" "$FRAMEWORKS_PATH" "$RESOURCES_PATH"

SWIFT_SOURCES=()
while IFS= read -r source; do
    SWIFT_SOURCES+=("$source")
done < <(find "${REPO_ROOT}/MeetMemo" -type f -name '*.swift' -print | sort)
[[ "${#SWIFT_SOURCES[@]}" -gt 0 ]] || die "No Swift sources found."

echo "🔨 Compiling ${APP_NAME} for Apple Silicon with Command Line Tools..."
swiftc \
    -O \
    -whole-module-optimization \
    -swift-version 5 \
    -D SHERPA_ONNX_ENABLED \
    -D ENABLE_TCC_SPI \
    -target arm64-apple-macosx15.5 \
    -module-name "$APP_NAME" \
    -module-cache-path "$MODULE_CACHE" \
    -import-objc-header "$BRIDGING_HEADER" \
    -Xcc "-I${SHERPA_HEADERS}" \
    -L "${REPO_ROOT}/Frameworks/onnxruntime/lib" \
    -lc++ \
    -lonnxruntime \
    "$SHERPA_LIBRARY" \
    -Xlinker -rpath \
    -Xlinker '@executable_path/../Frameworks' \
    -o "${MACOS_PATH}/${APP_NAME}" \
    "${SWIFT_SOURCES[@]}"

cp "$ONNXRUNTIME_SOURCE" "${FRAMEWORKS_PATH}/${ONNXRUNTIME_NAME}"
cp "${REPO_ROOT}/MeetMemo/Resources/DefaultSystemPrompt.txt" "$RESOURCES_PATH/"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/Icon32.imageset/Icon32.png" "${RESOURCES_PATH}/Icon32.png"

ICONSET_PATH="${STAGING_ROOT}/AppIcon.iconset"
mkdir -p "$ICONSET_PATH"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon16.png" "${ICONSET_PATH}/icon_16x16.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon32.png" "${ICONSET_PATH}/icon_16x16@2x.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon32 1.png" "${ICONSET_PATH}/icon_32x32.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon64.png" "${ICONSET_PATH}/icon_32x32@2x.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon128.png" "${ICONSET_PATH}/icon_128x128.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon256.png" "${ICONSET_PATH}/icon_128x128@2x.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon256 1.png" "${ICONSET_PATH}/icon_256x256.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon512.png" "${ICONSET_PATH}/icon_256x256@2x.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon512 1.png" "${ICONSET_PATH}/icon_512x512.png"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/AppIcon.appiconset/Icon1024.png" "${ICONSET_PATH}/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_PATH" -o "${RESOURCES_PATH}/AppIcon.icns"

cp "${REPO_ROOT}/MeetMemo/Info.plist" "${CONTENTS_PATH}/Info.plist"
PLIST="${CONTENTS_PATH}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${APP_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_IDENTIFIER}" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.59.1" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 29" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.productivity" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 15.5" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" "$PLIST"
plutil -convert binary1 "$PLIST"
plutil -lint "$PLIST"

# Ad-hoc signatures do not have an Apple Developer Team ID. Hardened Runtime's
# default library validation therefore rejects the separately signed ONNX
# Runtime dylib at launch, even though both signatures verify successfully.
# Keep the rest of Hardened Runtime enabled and add only the documented local
# library-validation exception. Release builds must continue using the normal
# project entitlements and a single real Developer ID identity instead.
LOCAL_ENTITLEMENTS="${STAGING_ROOT}/MeetMemo.local.entitlements"
cp "$SOURCE_ENTITLEMENTS" "$LOCAL_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c \
    "Add :com.apple.security.cs.disable-library-validation bool true" \
    "$LOCAL_ENTITLEMENTS"
plutil -lint "$LOCAL_ENTITLEMENTS"

chmod 755 "${MACOS_PATH}/${APP_NAME}" "${FRAMEWORKS_PATH}/${ONNXRUNTIME_NAME}"
codesign --force --sign - "${FRAMEWORKS_PATH}/${ONNXRUNTIME_NAME}"
codesign --force --sign - --options runtime \
    --entitlements "$LOCAL_ENTITLEMENTS" \
    "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNED_ENTITLEMENTS="${STAGING_ROOT}/MeetMemo.signed.entitlements"
codesign --display --entitlements "$SIGNED_ENTITLEMENTS" --xml "$APP_PATH"
[[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.cs.disable-library-validation' \
    "$SIGNED_ENTITLEMENTS")" == "true" ]] \
    || die "Local app is missing the library-validation exception required for ad-hoc signing."
file "${MACOS_PATH}/${APP_NAME}" | grep -Fq 'Mach-O 64-bit executable arm64'
otool -L "${MACOS_PATH}/${APP_NAME}" | grep -Fq "@rpath/${ONNXRUNTIME_NAME}"
[[ -f "${FRAMEWORKS_PATH}/${ONNXRUNTIME_NAME}" ]] || die "Embedded ONNX Runtime is missing."

ARCHIVE_PATH="${STAGING_ROOT}/MeetMemo-local-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
[[ -s "$ARCHIVE_PATH" ]] || die "Local app archive was not created."

if [[ -d "$DIST_ROOT" ]]; then
    PREVIOUS_DIST="${REPO_ROOT}/dist/local-clt.previous"
    rm -rf "$PREVIOUS_DIST"
    mv "$DIST_ROOT" "$PREVIOUS_DIST"
fi
mkdir -p "$DIST_ROOT"
mv "$APP_PATH" "$DIST_ROOT/"
mv "$ARCHIVE_PATH" "$DIST_ROOT/"

echo "✅ Local build complete (no source upload and no network access):"
echo "   ${DIST_ROOT}/${APP_BUNDLE}"
echo "   ${DIST_ROOT}/MeetMemo-local-macos-arm64.zip"
