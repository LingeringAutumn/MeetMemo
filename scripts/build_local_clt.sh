#!/bin/bash
# Build an arm64 MeetMemo.app with the already-installed Xcode Command Line Tools.
#
# This intentionally avoids xcodebuild, the Mac App Store, Apple-account authentication,
# and all network access. The sherpa-onnx/ONNX Runtime dependencies must already exist in
# ./Frameworks (run fetch_sherpa_frameworks.sh separately when downloads are permitted).

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_PROFILE="${MEETMEMO_BUILD_PROFILE:-public}"
readonly APP_EXECUTABLE="MeetMemo"
case "$BUILD_PROFILE" in
    public)
        readonly DIST_VARIANT="local-clt-fork"
        readonly APP_DISPLAY_NAME="MeetMemo Interview"
        readonly APP_BUNDLE_NAME="MeetMemo Interview"
        readonly BUNDLE_IDENTIFIER="io.github.lingeringautumn.meetmemo.interview"
        readonly ARCHIVE_NAME="MeetMemo-Interview-local-macos-arm64.zip"
        ;;
    compatibility)
        readonly DIST_VARIANT="local-clt-compatibility"
        readonly APP_DISPLAY_NAME="MeetMemo"
        readonly APP_BUNDLE_NAME="MeetMemo"
        readonly BUNDLE_IDENTIFIER="com.youcai.meetmemo"
        readonly ARCHIVE_NAME="MeetMemo-local-macos-arm64.zip"
        ;;
    *)
        echo "❌ MEETMEMO_BUILD_PROFILE must be 'public' or 'compatibility'." >&2
        exit 1
        ;;
esac
readonly DIST_ROOT="${REPO_ROOT}/dist/${DIST_VARIANT}"
readonly APP_BUNDLE="${APP_BUNDLE_NAME}.app"
readonly ONNXRUNTIME_VERSION="1.24.4"
readonly ONNXRUNTIME_NAME="libonnxruntime.${ONNXRUNTIME_VERSION}.dylib"
readonly SHERPA_LIBRARY="${REPO_ROOT}/Frameworks/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a"
readonly SHERPA_HEADERS="${REPO_ROOT}/Frameworks/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers"
readonly BRIDGING_HEADER="${REPO_ROOT}/Frameworks/swift-wrapper/SherpaOnnx-Bridging-Header.h"
readonly ONNXRUNTIME_SOURCE="${REPO_ROOT}/Frameworks/onnxruntime/lib/${ONNXRUNTIME_NAME}"
readonly SOURCE_ENTITLEMENTS="${REPO_ROOT}/MeetMemo/MeetMemo.entitlements"
readonly THIRD_PARTY_LICENSES="${REPO_ROOT}/ThirdPartyLicenses"

die() {
    echo "❌ $*" >&2
    exit 1
}

verify_license_tree() {
    local root="$1"
    local manifest="${root}/SHA256SUMS"
    [[ -f "$manifest" ]] || die "Missing license checksum manifest: ${manifest}"
    if find "$root" -type l -print -quit | grep -q .; then
        die "Third-party license material must not contain symbolic links: ${root}"
    fi
    diff -u \
        <(cd "$root" && LC_ALL=C find . -type f ! -name SHA256SUMS -print \
            | sed 's#^\./##' | LC_ALL=C sort) \
        <(sed -E 's/^[0-9a-fA-F]{64}  //' "$manifest" | LC_ALL=C sort) >/dev/null \
        || die "Third-party license file list does not match ${manifest}."
    (cd "$root" && shasum -a 256 -c SHA256SUMS >/dev/null) \
        || die "Third-party license checksum verification failed: ${root}"
}

contains_forbidden_tts_implementation() {
    local binary="$1"
    nm "$binary" 2>/dev/null |
        grep -Ei '(^|[[:space:]])(_?(AppendPhonemes|DecodePhonemes)|_?espeak(_ng)?_[[:alnum:]_]+|_?phonemize(_[[:alnum:]_]+)?)([[:space:]]|$)|piper[-_]phonemize' >/dev/null && return 0
    strings "$binary" |
        grep -Ei 'piper[-_]phonemize|espeak-ng-data|libespeak|/espeak([/_.-]|$)|AppendPhonemes|DecodePhonemes' >/dev/null
}

verify_no_tts_sherpa_library() {
    local library="$1"
    local architectures
    architectures="$(lipo -archs "$library" 2>/dev/null)" ||
        die "Unable to inspect sherpa-onnx library architectures."
    [[ " ${architectures} " == *" arm64 "* && " ${architectures} " == *" x86_64 "* ]] ||
        die "sherpa-onnx must contain both arm64 and x86_64 slices."
    local symbol
    for symbol in \
        SherpaOnnxCreateOfflineRecognizer \
        SherpaOnnxCreateVoiceActivityDetector \
        SherpaOnnxCreateSpeakerEmbeddingExtractor; do
        nm -gU -arch arm64 "$library" 2>/dev/null |
            grep -E "[[:space:]]T[[:space:]]_${symbol}$" >/dev/null ||
            die "sherpa-onnx is missing required arm64 ASR symbol ${symbol}."
    done
    if contains_forbidden_tts_implementation "$library"; then
        die "sherpa-onnx contains eSpeak-ng/Piper TTS implementation objects. Run scripts/fetch_sherpa_frameworks.sh to install the pinned static-no-tts build."
    fi
}

[[ "$BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] \
    || die "Invalid reverse-DNS bundle identifier: ${BUNDLE_IDENTIFIER}"

for tool in swiftc codesign iconutil plutil ditto file otool lipo nm strings grep cmp \
    find sed sort diff shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required local tool: ${tool}"
done
[[ -x /usr/libexec/PlistBuddy ]] || die "Missing /usr/libexec/PlistBuddy"
[[ -f "$SHERPA_LIBRARY" ]] || die "Missing ${SHERPA_LIBRARY}. Fetch the pinned frameworks first."
[[ -d "$SHERPA_HEADERS" ]] || die "Missing sherpa-onnx headers: ${SHERPA_HEADERS}"
[[ -f "$BRIDGING_HEADER" ]] || die "Missing bridging header: ${BRIDGING_HEADER}"
[[ -f "$ONNXRUNTIME_SOURCE" ]] || die "Missing ${ONNXRUNTIME_SOURCE}"
verify_license_tree "$THIRD_PARTY_LICENSES"
verify_no_tts_sherpa_library "$SHERPA_LIBRARY"

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

echo "🔨 Compiling ${APP_DISPLAY_NAME} for Apple Silicon with Command Line Tools..."
swiftc \
    -O \
    -whole-module-optimization \
    -swift-version 5 \
    -D SHERPA_ONNX_ENABLED \
    -D ENABLE_TCC_SPI \
    -target arm64-apple-macosx15.5 \
    -module-name "$APP_EXECUTABLE" \
    -module-cache-path "$MODULE_CACHE" \
    -import-objc-header "$BRIDGING_HEADER" \
    -Xcc "-I${SHERPA_HEADERS}" \
    -L "${REPO_ROOT}/Frameworks/onnxruntime/lib" \
    -lc++ \
    -lonnxruntime \
    "$SHERPA_LIBRARY" \
    -Xlinker -rpath \
    -Xlinker '@executable_path/../Frameworks' \
    -o "${MACOS_PATH}/${APP_EXECUTABLE}" \
    "${SWIFT_SOURCES[@]}"

cp "$ONNXRUNTIME_SOURCE" "${FRAMEWORKS_PATH}/${ONNXRUNTIME_NAME}"
cp "${REPO_ROOT}/MeetMemo/Resources/DefaultSystemPrompt.txt" "$RESOURCES_PATH/"
cp "${REPO_ROOT}/MeetMemo/Assets.xcassets/Icon32.imageset/Icon32.png" "${RESOURCES_PATH}/Icon32.png"
cp "${REPO_ROOT}/LICENSE" "$RESOURCES_PATH/LICENSE.txt"
cp "${REPO_ROOT}/NOTICE.md" "$RESOURCES_PATH/NOTICE.md"
cp "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" "$RESOURCES_PATH/THIRD_PARTY_NOTICES.md"
cp -R "$THIRD_PARTY_LICENSES" "$RESOURCES_PATH/ThirdPartyLicenses"
verify_license_tree "$RESOURCES_PATH/ThirdPartyLicenses"
cmp "${THIRD_PARTY_LICENSES}/onnxruntime/ThirdPartyNotices.txt" \
    "${RESOURCES_PATH}/ThirdPartyLicenses/onnxruntime/ThirdPartyNotices.txt" >/dev/null \
    || die "Bundled ONNX Runtime notices differ from the verified source file."

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
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_DISPLAY_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${APP_EXECUTABLE}" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_IDENTIFIER}" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_DISPLAY_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.59.2" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 30" "$PLIST"
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
    "Set :com.apple.security.temporary-exception.mach-lookup.global-name:0 ${BUNDLE_IDENTIFIER}-spks" \
    "$LOCAL_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c \
    "Set :com.apple.security.temporary-exception.mach-lookup.global-name:1 ${BUNDLE_IDENTIFIER}-spki" \
    "$LOCAL_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c \
    "Add :com.apple.security.cs.disable-library-validation bool true" \
    "$LOCAL_ENTITLEMENTS"
plutil -lint "$LOCAL_ENTITLEMENTS"

chmod 755 "${MACOS_PATH}/${APP_EXECUTABLE}" "${FRAMEWORKS_PATH}/${ONNXRUNTIME_NAME}"
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
[[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.temporary-exception.mach-lookup.global-name:0' \
    "$SIGNED_ENTITLEMENTS")" == "${BUNDLE_IDENTIFIER}-spks" ]] \
    || die "Signed app has a stale speech-service entitlement namespace."
[[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.temporary-exception.mach-lookup.global-name:1' \
    "$SIGNED_ENTITLEMENTS")" == "${BUNDLE_IDENTIFIER}-spki" ]] \
    || die "Signed app has a stale speech-service entitlement namespace."
file "${MACOS_PATH}/${APP_EXECUTABLE}" | grep -Fq 'Mach-O 64-bit executable arm64'
otool -L "${MACOS_PATH}/${APP_EXECUTABLE}" | grep -Fq "@rpath/${ONNXRUNTIME_NAME}"
[[ -f "${FRAMEWORKS_PATH}/${ONNXRUNTIME_NAME}" ]] || die "Embedded ONNX Runtime is missing."
if contains_forbidden_tts_implementation "${MACOS_PATH}/${APP_EXECUTABLE}"; then
    die "The linked application unexpectedly contains eSpeak-ng/Piper TTS implementation symbols."
fi

ARCHIVE_PATH="${STAGING_ROOT}/${ARCHIVE_NAME}"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
[[ -s "$ARCHIVE_PATH" ]] || die "Local app archive was not created."

# Verify the exact archive users will install, not merely the pre-archive app.
ARCHIVE_VERIFY_ROOT="${STAGING_ROOT}/archive-roundtrip"
mkdir -p "$ARCHIVE_VERIFY_ROOT"
ditto -x -k "$ARCHIVE_PATH" "$ARCHIVE_VERIFY_ROOT"
EXTRACTED_APP="${ARCHIVE_VERIFY_ROOT}/${APP_BUNDLE}"
[[ -d "$EXTRACTED_APP" ]] || die "Archive round-trip did not contain ${APP_BUNDLE}."
EXTRACTED_PLIST="${EXTRACTED_APP}/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$EXTRACTED_PLIST")" == "$BUNDLE_IDENTIFIER" ]] \
    || die "Archive Bundle ID does not match the selected build profile."
[[ "$(plutil -extract CFBundleDisplayName raw -o - "$EXTRACTED_PLIST")" == "$APP_DISPLAY_NAME" ]] \
    || die "Archive display name does not match the selected build profile."
[[ "$(plutil -extract CFBundleName raw -o - "$EXTRACTED_PLIST")" == "$APP_DISPLAY_NAME" ]] \
    || die "Archive bundle name does not match the selected build profile."
codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
EXTRACTED_ENTITLEMENTS="${STAGING_ROOT}/MeetMemo.extracted.entitlements"
codesign --display --entitlements "$EXTRACTED_ENTITLEMENTS" --xml "$EXTRACTED_APP"
[[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.app-sandbox' "$EXTRACTED_ENTITLEMENTS")" == "true" ]] \
    || die "Archive is missing the App Sandbox entitlement."
[[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.temporary-exception.mach-lookup.global-name:0' \
    "$EXTRACTED_ENTITLEMENTS")" == "${BUNDLE_IDENTIFIER}-spks" ]] \
    || die "Archive contains a stale speech-service entitlement namespace."
[[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.temporary-exception.mach-lookup.global-name:1' \
    "$EXTRACTED_ENTITLEMENTS")" == "${BUNDLE_IDENTIFIER}-spki" ]] \
    || die "Archive contains a stale speech-service entitlement namespace."
file "${EXTRACTED_APP}/Contents/MacOS/${APP_EXECUTABLE}" | grep -Fq 'Mach-O 64-bit executable arm64'
otool -L "${EXTRACTED_APP}/Contents/MacOS/${APP_EXECUTABLE}" \
    | grep -Fq "@rpath/${ONNXRUNTIME_NAME}"
verify_license_tree "${EXTRACTED_APP}/Contents/Resources/ThirdPartyLicenses"
if contains_forbidden_tts_implementation "${EXTRACTED_APP}/Contents/MacOS/${APP_EXECUTABLE}"; then
    die "The archived application unexpectedly contains eSpeak-ng/Piper TTS implementation symbols."
fi

(cd "$STAGING_ROOT" && shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS.txt)
BUILD_VERIFICATION_PATH="${STAGING_ROOT}/BUILD_VERIFICATION.md"
cat > "$BUILD_VERIFICATION_PATH" <<EOF
# Build verification

- Profile: ${BUILD_PROFILE}
- App: ${APP_BUNDLE}
- Bundle ID: ${BUNDLE_IDENTIFIER}
- Version/build: 0.59.2 (30)
- Target: arm64-apple-macosx15.5
- Build host: $(sw_vers -productVersion) / $(uname -m)
- Verified: optimized whole-module Swift compile and link
- Verified: deep strict code-sign validation before and after ZIP round-trip
- Verified: App Sandbox and bundle-scoped speech-service entitlements
- Verified: embedded ONNX Runtime linkage and complete third-party license SHA-256 manifest
- Verified: no linked eSpeak-ng/Piper TTS implementation symbols
- Limitation: ad-hoc signed and not Apple-notarized; this is a local test build
- Limitation: XCTest was not executed because this Mac has Command Line Tools but not full Xcode
EOF

if [[ -d "$DIST_ROOT" ]]; then
    PREVIOUS_DIST="${REPO_ROOT}/dist/${DIST_VARIANT}.previous-$(date '+%Y%m%d-%H%M%S')"
    previous_suffix=1
    while [[ -e "$PREVIOUS_DIST" ]]; do
        PREVIOUS_DIST="${REPO_ROOT}/dist/${DIST_VARIANT}.previous-$(date '+%Y%m%d-%H%M%S')-${previous_suffix}"
        previous_suffix=$((previous_suffix + 1))
    done
    mv "$DIST_ROOT" "$PREVIOUS_DIST"
fi
mkdir -p "$DIST_ROOT"
mv "$APP_PATH" "$DIST_ROOT/"
mv "$ARCHIVE_PATH" "$DIST_ROOT/"
mv "${STAGING_ROOT}/SHA256SUMS.txt" "$DIST_ROOT/"
mv "$BUILD_VERIFICATION_PATH" "$DIST_ROOT/"

echo "✅ Local build complete (no source upload and no network access):"
echo "   ${DIST_ROOT}/${APP_BUNDLE}"
echo "   ${DIST_ROOT}/${ARCHIVE_NAME}"
echo "   ${DIST_ROOT}/SHA256SUMS.txt"
echo "   ${DIST_ROOT}/BUILD_VERIFICATION.md"
