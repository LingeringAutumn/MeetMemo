#!/bin/bash

# Verify Code Signing Setup for MeetMemo
# This script checks if your Apple Developer credentials are properly configured

set -euo pipefail

if [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
fi

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "🔍 Code Signing Verification"
echo "============================"
echo ""

# Check environment variables
echo "📋 Environment Variables:"

if [ -n "$DEVELOPER_ID" ]; then
    echo "   ✅ DEVELOPER_ID is configured"
else
    echo "   ❌ DEVELOPER_ID: Not set (REQUIRED)"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    echo "   ✅ NOTARY_PROFILE is configured (credentials remain in Keychain)"
else
    echo "   ❌ NOTARY_PROFILE is not set"
fi

echo ""

# Check certificates
echo "🔍 Available Certificates:"
DEVELOPER_ID_CERTS=$(security find-identity -v -p codesigning | grep "Developer ID Application" || true)
if [ -n "$DEVELOPER_ID_CERTS" ]; then
    echo "   ✅ Developer ID Application certificates found:"
    echo "$DEVELOPER_ID_CERTS" | sed 's/^/      /'
else
    echo "   ❌ No Developer ID Application certificates found"
fi

echo ""

# Validate certificate matches expected
if [ -n "$DEVELOPER_ID_CERTS" ]; then
    echo "   ✅ Developer ID Application certificates are available"
else
    echo "   ❌ No Developer ID Application certificates found"
    echo "      Install your certificate from Apple Developer portal"
fi

echo ""

# Check notarytool
echo "🔍 Notarization Tools:"
if command -v xcrun &> /dev/null; then
    if xcrun --find notarytool &> /dev/null; then
        echo "   ✅ notarytool available"
    else
        echo "   ❌ notarytool not found (requires Xcode 13+)"
    fi
else
    echo "   ❌ xcrun not available"
fi

echo ""

# Check entitlements file
echo "🔍 Entitlements File:"
if [ -f "MeetMemo/MeetMemo.entitlements" ]; then
    echo "   ✅ MeetMemo.entitlements found"
else
    echo "   ❌ MeetMemo.entitlements not found"
fi

echo ""

# Overall status
echo "📊 Overall Status:"
CERT_OK=$(echo "$DEVELOPER_ID_CERTS" | grep -q "Developer ID Application" && echo "true" || echo "false")
CREDS_OK=$([ -n "$DEVELOPER_ID" ] && [ -n "$NOTARY_PROFILE" ] && echo "true" || echo "false")

if [ "$CERT_OK" = "true" ] && [ "$CREDS_OK" = "true" ]; then
    echo "   🎉 Ready for production builds with notarization!"
elif [ "$CERT_OK" = "true" ]; then
    echo "   ⚠️  Certificate installed, but missing environment variables"
else
    echo "   ❌ Missing certificate or environment variables"
fi

echo ""
echo "🚀 Next Steps:"
if [ "$CERT_OK" = "false" ]; then
    echo "   1. Install your Developer ID certificate in Keychain"
    echo "   2. Store notarization credentials with: xcrun notarytool store-credentials"
    echo "   3. Copy .env.template to .env and run: chmod 600 .env"
elif [ "$CREDS_OK" = "false" ]; then
    echo "   1. Store notarization credentials with: xcrun notarytool store-credentials"
    echo "   2. Configure DEVELOPER_ID and NOTARY_PROFILE in .env"
    echo "   3. Run: chmod 600 .env && ./scripts/verify_codesigning.sh"
else
    echo "   1. Run: ./scripts/build_release.sh"
    echo "   2. Test the resulting DMG on another Mac"
    echo "   3. Upload to GitHub releases"
fi

echo ""
echo "💡 Quick setup with .env file:"
echo "   1. Copy .env.template to .env: cp .env.template .env"
echo "   2. Edit only the certificate name and Keychain profile name"
echo "   3. Protect and verify: chmod 600 .env && ./scripts/verify_codesigning.sh"
