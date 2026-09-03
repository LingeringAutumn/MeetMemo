#!/bin/bash

# Build and Release Script for MeetMemo
# This script builds the app and creates a notarized DMG

set -euo pipefail

# Configuration
APP_NAME="MeetMemo Interview"
BUNDLE_IDENTIFIER="io.github.lingeringautumn.meetmemo.interview"
VERSION=$(grep -m1 "MARKETING_VERSION" MeetMemo.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/')

die() {
    echo "❌ $*" >&2
    exit 1
}

verify_license_tree() {
    local root="$1"
    local manifest="${root}/SHA256SUMS"
    [ -f "$manifest" ] || die "Missing license checksum manifest: ${manifest}"
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

# Source environment variables if .env file exists
if [ -f ".env" ]; then
    ENV_MODE="$(stat -f '%Lp' .env)"
    case "$ENV_MODE" in
        400|600) ;;
        *) die ".env must be readable only by its owner (chmod 600 .env)." ;;
    esac
    echo "📄 Loading environment variables from .env file..."
    source .env
fi

# Production code signing configuration
DEVELOPER_ID="${DEVELOPER_ID:-}"

# Store Apple notarization credentials in Keychain with `notarytool`
# store-credentials`; never pass an app-specific password in argv or .env.
NOTARY_PROFILE="${NOTARY_PROFILE:-meetmemo-interview-notary}"

if [ -z "$VERSION" ]; then
    echo "❌ Could not determine version from project file"
    echo "   Make sure MeetMemo.xcodeproj/project.pbxproj exists and contains MARKETING_VERSION"
    exit 1
fi

for required_tool in xcodebuild codesign xcrun create-dmg ditto plutil lipo shasum \
    find sed sort diff stat spctl nm strings grep; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        echo "❌ Missing required tool: $required_tool"
        echo "   Install it or make sure it is available in PATH before running this script."
        exit 1
    fi
done

verify_license_tree "ThirdPartyLicenses"

BUILD_DIR="$(pwd)/build"
RELEASES_DIR="$(pwd)/releases"
# Keep each release in its own sub-folder (e.g. releases/v0.12)
VERSION_DIR="${RELEASES_DIR}/v${VERSION}"
mkdir -p "$VERSION_DIR"

DMG_NAME="MeetMemo-Interview.dmg"
# Absolute paths for the artifacts
DMG_PATH="${VERSION_DIR}/${DMG_NAME}"

echo "🚀 Building ${APP_NAME} v${VERSION}..."

# Make sure third-party xcframeworks (sherpa-onnx + onnxruntime) are in place
# before Xcode tries to link them. The fetch script is idempotent.
echo "📦 Ensuring sherpa-onnx xcframeworks are present..."
"$(dirname "$0")/fetch_sherpa_frameworks.sh"

# Check signing configuration
# Verify notarization credentials
if [ -z "$DEVELOPER_ID" ] || [ -z "$NOTARY_PROFILE" ]; then
    echo "❌ Missing required credentials!"
    echo ""
    echo "📝 Required environment variables:"
    echo "   DEVELOPER_ID   - Your Developer ID Application certificate name"
    echo "   NOTARY_PROFILE - notarytool Keychain profile name"
    echo ""
    echo "🔧 Store notarization credentials interactively (password is prompted):"
    echo "   xcrun notarytool store-credentials \"meetmemo-interview-notary\" --apple-id \"you@example.com\" --team-id \"YOUR_TEAM_ID\""
    echo "   Then create a chmod-600 .env containing only DEVELOPER_ID and NOTARY_PROFILE."
    echo "   Then run: ./scripts/build_release.sh"
    echo ""
    exit 1
fi

# Clean and build a *universal* binary (arm64 + x86_64)
# -----------------------------------------------------
# Xcode will only build the active architecture by default ("My Mac") which results in an
# Apple-silicon-only binary when run on an M-series machine. By explicitly passing both
# architectures and using the generic macOS destination we ensure a universal build.
# The resulting binary is produced at the usual DerivedData location so the rest of the
# script can continue to reference $APP_PATH unchanged.

ARCHS="arm64 x86_64"

echo "📦 Building universal app (archs: $ARCHS)..."
xcodebuild \
  -project MeetMemo.xcodeproj \
  -scheme MeetMemo \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  -destination 'generic/platform=macOS' \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  PRODUCT_NAME="$APP_NAME" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  clean build

# Find the built app
APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at $APP_PATH"
    exit 1
fi

APP_PLIST="$APP_PATH/Contents/Info.plist"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_PLIST")" = "$BUNDLE_IDENTIFIER" ] \
    || die "Built app has an unexpected Bundle ID."
[ "$(plutil -extract CFBundleDisplayName raw -o - "$APP_PLIST")" = "$APP_NAME" ] \
    || die "Built app has an unexpected display name."
[ "$(plutil -extract CFBundleName raw -o - "$APP_PLIST")" = "$APP_NAME" ] \
    || die "Built app has an unexpected bundle name."
APP_EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "$APP_PLIST")"
APP_EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
APP_ARCHS="$(lipo -archs "$APP_EXECUTABLE_PATH")"
[[ " $APP_ARCHS " == *" arm64 "* && " $APP_ARCHS " == *" x86_64 "* ]] \
    || die "Production app must contain both arm64 and x86_64 slices."

# Preserve the upstream-required notice and third-party attribution in every
# distributed binary before the final signature is applied.
install -m 0644 LICENSE "$APP_PATH/Contents/Resources/LICENSE.txt"
install -m 0644 NOTICE.md "$APP_PATH/Contents/Resources/NOTICE.md"
install -m 0644 THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R ThirdPartyLicenses "$APP_PATH/Contents/Resources/ThirdPartyLicenses"
verify_license_tree "$APP_PATH/Contents/Resources/ThirdPartyLicenses"
cmp ThirdPartyLicenses/onnxruntime/ThirdPartyNotices.txt \
    "$APP_PATH/Contents/Resources/ThirdPartyLicenses/onnxruntime/ThirdPartyNotices.txt" \
    || { echo "❌ Bundled ONNX Runtime notices failed byte-for-byte verification"; exit 1; }

# 🔏 Production code signing with hardened runtime -------------------------------------------------

echo "🔏 Code signing all embedded frameworks and components..."

# Xcode copies ONNX Runtime as a standalone dylib rather than a .framework.
# It must be signed before the outer app or the final deep verification and
# notarization fail even though the main executable itself is signed.
while IFS= read -r -d '' dylib; do
    echo "   Signing dynamic library: $(basename "$dylib")"
    codesign \
      --force \
      --options runtime \
      --sign "$DEVELOPER_ID" \
      --timestamp \
      "$dylib"
done < <(find "$APP_PATH/Contents" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)

# Sign all embedded frameworks and their components first.
# This is required for notarization - we must sign from the inside out.
while IFS= read -r -d '' framework; do
    echo "   Signing framework: $(basename "$framework")"

    # Sign all binaries within the framework
    while IFS= read -r -d '' binary; do
        echo "      Signing binary: $(basename "$binary")"
        codesign \
          --force \
          --options runtime \
          --sign "$DEVELOPER_ID" \
          --timestamp \
          "$binary"
    done < <(find "$framework" -type f -perm +111 \
        -exec sh -c 'file "$1" | grep -q "Mach-O"' _ {} \; -print0)

    # Sign the framework itself
    codesign \
      --force \
      --options runtime \
      --sign "$DEVELOPER_ID" \
      --timestamp \
      "$framework"
done < <(find "$APP_PATH" -name "*.framework" -type d -print0)

# Sign all XPC services
while IFS= read -r -d '' xpc; do
    echo "   Signing XPC service: $(basename "$xpc")"
    codesign \
      --force \
      --options runtime \
      --sign "$DEVELOPER_ID" \
      --timestamp \
      "$xpc"
done < <(find "$APP_PATH" -name "*.xpc" -type d -print0)

# Sign all nested apps
while IFS= read -r -d '' app; do
    echo "   Signing nested app: $(basename "$app")"
    codesign \
      --force \
      --options runtime \
      --sign "$DEVELOPER_ID" \
      --timestamp \
      "$app"
done < <(find "$APP_PATH" -mindepth 2 -name "*.app" -type d -print0)

echo "🔏 Code signing the main app with hardened runtime..."
codesign \
  --force \
  --options runtime \
  --entitlements "MeetMemo/MeetMemo.entitlements" \
  --sign "$DEVELOPER_ID" \
  --timestamp \
  "$APP_PATH"

# Validate the signature before packaging
echo "✅ Validating code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNED_ENTITLEMENTS="${BUILD_DIR}/MeetMemo-Interview.signed.entitlements"
codesign --display --entitlements "$SIGNED_ENTITLEMENTS" --xml "$APP_PATH"
[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.app-sandbox' "$SIGNED_ENTITLEMENTS")" = "true" ] \
    || die "Signed app is missing App Sandbox."
[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.temporary-exception.mach-lookup.global-name:0' \
    "$SIGNED_ENTITLEMENTS")" = "${BUNDLE_IDENTIFIER}-spks" ] \
    || die "Signed app has a stale speech-service entitlement namespace."
[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.temporary-exception.mach-lookup.global-name:1' \
    "$SIGNED_ENTITLEMENTS")" = "${BUNDLE_IDENTIFIER}-spki" ] \
    || die "Signed app has a stale speech-service entitlement namespace."
CODESIGN_DETAILS="${BUILD_DIR}/MeetMemo-Interview.codesign.txt"
codesign --display --verbose=4 "$APP_PATH" >"$CODESIGN_DETAILS" 2>&1
TEAM_IDENTIFIER="$(sed -n 's/^TeamIdentifier=//p' "$CODESIGN_DETAILS" | head -n 1)"
[[ -n "$TEAM_IDENTIFIER" && "$TEAM_IDENTIFIER" != "not set" ]] \
    || die "Signed production app has no real Developer Team identifier."
grep -Eq '^Authority=Developer ID Application:' "$CODESIGN_DETAILS" \
    || die "Production app was not signed with a Developer ID Application certificate."
grep -Eq '^flags=.*\(.*runtime.*\)' "$CODESIGN_DETAILS" \
    || die "Signed production app is missing Hardened Runtime."
if contains_forbidden_tts_implementation "$APP_EXECUTABLE_PATH"; then
    die "Production app unexpectedly contains eSpeak-ng/Piper TTS implementation symbols."
fi

echo "✅ App built and signed successfully at $APP_PATH"

# Create and notarize in a hidden staging directory. A failed or interrupted
# notarization must never leave a canonical-looking asset in releases/.
echo "📀 Creating staged DMG..."
RELEASE_STAGING="$(mktemp -d "${VERSION_DIR}/.release-staging.XXXXXX")"
cleanup_release_staging() {
    rm -rf "$RELEASE_STAGING"
}
trap cleanup_release_staging EXIT
PENDING_DMG="${RELEASE_STAGING}/${DMG_NAME}"
DMG_SOURCE="${RELEASE_STAGING}/dmg-source"
mkdir -p "$DMG_SOURCE"
# create-dmg copies the *contents* of its source folder. Put the complete app
# bundle inside a dedicated source directory so the image contains
# `MeetMemo Interview.app`, never the app's internal `Contents/` at its root.
ditto "$APP_PATH" "${DMG_SOURCE}/${APP_NAME}.app"
[ -d "${DMG_SOURCE}/${APP_NAME}.app/Contents" ] \
    || die "DMG staging does not contain a complete app bundle."
create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 200 190 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 600 185 \
    "$PENDING_DMG" \
    "$DMG_SOURCE"

echo "🔏 Signing and validating the staged DMG..."
codesign \
    --force \
    --sign "$DEVELOPER_ID" \
    --timestamp \
    --identifier "${BUNDLE_IDENTIFIER}.disk-image" \
    "$PENDING_DMG"
codesign --verify --strict --verbose=2 "$PENDING_DMG"

echo "✅ Staged DMG created and Developer ID signed."

# 📡 Notarization (required for all production builds)
echo "📡 Starting notarization process..."

# Submit for notarization
echo "📤 Submitting DMG for notarization..."
NOTARIZATION_JSON="${RELEASE_STAGING}/notarization.json"
xcrun notarytool submit "$PENDING_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$NOTARIZATION_JSON"
NOTARIZATION_STATUS="$(plutil -extract status raw -o - "$NOTARIZATION_JSON")"
[ "$NOTARIZATION_STATUS" = "Accepted" ] \
    || die "Apple notarization did not return Accepted (status: ${NOTARIZATION_STATUS})."

echo "📎 Stapling and validating notarization ticket..."
xcrun stapler staple "$PENDING_DMG"
xcrun stapler validate "$PENDING_DMG"
codesign --verify --strict --verbose=2 "$PENDING_DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$PENDING_DMG"

(cd "$RELEASE_STAGING" && shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt)
cat >"${RELEASE_STAGING}/BUILD_VERIFICATION.md" <<EOF
# Production release verification

- App: ${APP_NAME}.app
- Bundle ID: ${BUNDLE_IDENTIFIER}
- Version: ${VERSION}
- Architectures: arm64, x86_64
- Verified: complete third-party-license SHA-256 manifest
- Verified: nested-code, app, and DMG Developer ID signatures
- Verified: App Sandbox, bundle-scoped speech-service entitlements, and Hardened Runtime
- Verified: no linked eSpeak-ng/Piper TTS implementation symbols
- Verified: Apple notarization Accepted, ticket stapled and validated, Gatekeeper assessment passed
EOF

# Only fully verified assets receive the public filenames. Move older canonical
# outputs to a separate rollback directory so they cannot be mistaken for the
# current release or uploaded by a broad glob.
ROLLBACK_ROOT="${RELEASES_DIR}/archive/v${VERSION}"
ROLLBACK_DIR="${ROLLBACK_ROOT}/$(date '+%Y%m%d-%H%M%S')"
rollback_suffix=1
while [ -e "$ROLLBACK_DIR" ]; do
    ROLLBACK_DIR="${ROLLBACK_ROOT}/$(date '+%Y%m%d-%H%M%S')-${rollback_suffix}"
    rollback_suffix=$((rollback_suffix + 1))
done
mkdir -p "$ROLLBACK_DIR"
for existing in "$DMG_PATH" "${VERSION_DIR}/SHA256SUMS.txt" "${VERSION_DIR}/BUILD_VERIFICATION.md"; do
    if [ -e "$existing" ]; then
        mv "$existing" "$ROLLBACK_DIR/"
    fi
done
mv "$PENDING_DMG" "$DMG_PATH"
mv "${RELEASE_STAGING}/SHA256SUMS.txt" "${VERSION_DIR}/SHA256SUMS.txt"
mv "${RELEASE_STAGING}/BUILD_VERIFICATION.md" "${VERSION_DIR}/BUILD_VERIFICATION.md"
rm -rf "$RELEASE_STAGING"
trap - EXIT

echo "✅ DMG notarized, validated, and published to the local release directory."

# Show file sizes
echo ""
echo "📊 Release Summary:"
echo "   Version: $VERSION"
echo "   DMG: $DMG_NAME ($(du -h "$DMG_PATH" | cut -f1))"
echo "   Checksums: ${VERSION_DIR}/SHA256SUMS.txt"
echo "   Verification: ${VERSION_DIR}/BUILD_VERIFICATION.md"
echo "   Location: $VERSION_DIR"
echo "   Code Signing: ✅ Production (production Developer ID)"
echo "   Notarization (DMG): ✅ Complete"
echo ""
echo "🎉 Production release ready! Next steps:"
echo "   1. Test the DMG on another Mac"
echo "   2. Create a GitHub release with tag v${VERSION}"
echo "   3. Upload the DMG to the GitHub release"
