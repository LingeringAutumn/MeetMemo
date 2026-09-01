#!/bin/bash
# Fetch the reproducible sherpa-onnx build dependencies into ./Frameworks/.
#
# The defaults are intentionally pinned. Upstream release assets and ONNX Runtime
# versions change independently, so following a moving "latest" release can make a
# clean checkout impossible to build. To test another sherpa-onnx release, callers
# must provide all three expected SHA-256 values explicitly.

set -euo pipefail

readonly DEFAULT_SHERPA_ONNX_VERSION="v1.13.2"
readonly ONNXRUNTIME_VERSION="1.24.4"
readonly DEFAULT_XCFW_SHA256="8756afb64ef7a1d612040c323e6f2cf707f90e703395413c79c572e37eddd65e"
readonly DEFAULT_ORT_SHA256="41e71d17eb9b4eb5ee28258d6c081d21d9061a41d826830be59c283c68326b02"
readonly DEFAULT_WRAPPER_SHA256="eb217f425b809fb17d97b1d214fa056c25796337e367390a24c4f04901d27540"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS_DIR="${REPO_ROOT}/Frameworks"
WRAPPER_DIR="${FRAMEWORKS_DIR}/swift-wrapper"
SHERPA_ONNX_VERSION="${SHERPA_ONNX_VERSION:-$DEFAULT_SHERPA_ONNX_VERSION}"
FORCE_REFETCH="${SHERPA_ONNX_FORCE_REFETCH:-0}"

SHERPA_XCFW="${FRAMEWORKS_DIR}/sherpa-onnx.xcframework"
ONNXRUNTIME_LIB_DIR="${FRAMEWORKS_DIR}/onnxruntime/lib"
ONNXRUNTIME_DYLIB_NAME="libonnxruntime.${ONNXRUNTIME_VERSION}.dylib"
ONNXRUNTIME_DYLIB="${ONNXRUNTIME_LIB_DIR}/${ONNXRUNTIME_DYLIB_NAME}"
ONNXRUNTIME_SYMLINK="${ONNXRUNTIME_LIB_DIR}/libonnxruntime.dylib"
WRAPPER_SWIFT="${WRAPPER_DIR}/SherpaOnnx.swift"
WRAPPER_HEADER="${WRAPPER_DIR}/SherpaOnnx-Bridging-Header.h"
COMPILED_WRAPPER_SWIFT="${REPO_ROOT}/MeetMemo/SherpaOnnxBridge/SherpaOnnx.swift"
VERSION_STAMP="${FRAMEWORKS_DIR}/.sherpa-onnx-version"

die() {
    echo "❌ $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local label="$3"
    local actual
    actual="$(sha256_of "$file")"
    if [[ "$actual" != "$expected" ]]; then
        die "SHA-256 mismatch for ${label}. Expected ${expected}, got ${actual}. The file was not installed."
    fi
}

download_file() {
    local url="$1"
    local destination="$2"
    local label="$3"

    echo "⬇️  Downloading ${label}"
    echo "   ${url}"
    if ! curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 30 \
        --progress-bar --output "$destination" "$url"; then
        die "Failed to download ${label}. Check network access and confirm that release ${SHERPA_ONNX_VERSION} still publishes the required asset."
    fi
}

extract_archive() {
    local archive="$1"
    local destination="$2"
    mkdir -p "$destination"

    case "$archive" in
        *.tar.bz2) tar -xjf "$archive" -C "$destination" ;;
        *.tar.gz|*.tgz) tar -xzf "$archive" -C "$destination" ;;
        *.zip) unzip -q "$archive" -d "$destination" ;;
        *) die "Unsupported archive type: $archive" ;;
    esac
}

xcframework_is_valid() {
    local framework="$1"
    [[ -f "${framework}/Info.plist" ]] || return 1

    /usr/bin/python3 - "${framework}/Info.plist" <<'PY' >/dev/null 2>&1
import plistlib
import pathlib
import subprocess
import sys

plist_path = pathlib.Path(sys.argv[1])
with plist_path.open("rb") as handle:
    info = plistlib.load(handle)

libraries = info.get("AvailableLibraries", [])
mac_libraries = [item for item in libraries if item.get("SupportedPlatform") == "macos"]
architectures = {
    arch
    for item in mac_libraries
    for arch in item.get("SupportedArchitectures", [])
}

if not {"arm64", "x86_64"}.issubset(architectures):
    raise SystemExit("xcframework does not contain both macOS arm64 and x86_64 slices")

for item in mac_libraries:
    binary_path = plist_path.parent / item["LibraryIdentifier"] / item["BinaryPath"]
    if not binary_path.is_file():
        raise SystemExit(f"xcframework binary is missing: {binary_path}")
    actual_architectures = set(
        subprocess.check_output(["lipo", "-archs", str(binary_path)], text=True).split()
    )
    declared_architectures = set(item.get("SupportedArchitectures", []))
    if not declared_architectures.issubset(actual_architectures):
        raise SystemExit(
            f"xcframework binary architectures {actual_architectures} do not match "
            f"Info.plist declarations {declared_architectures}"
        )
PY
}

onnxruntime_is_valid() {
    local dylib="$1"
    local architectures
    [[ -f "$dylib" ]] || return 1
    architectures="$(lipo -archs "$dylib" 2>/dev/null)" || return 1
    [[ " ${architectures} " == *" arm64 "* && " ${architectures} " == *" x86_64 "* ]]
}

onnxruntime_install_is_valid() {
    onnxruntime_is_valid "$ONNXRUNTIME_DYLIB" &&
        [[ -L "$ONNXRUNTIME_SYMLINK" ]] &&
        [[ "$(readlink "$ONNXRUNTIME_SYMLINK")" == "$ONNXRUNTIME_DYLIB_NAME" ]]
}

wrapper_is_valid() {
    local wrapper="$1"
    local expected="$2"
    [[ -s "$wrapper" ]] || return 1
    [[ "$(sha256_of "$wrapper")" == "$expected" ]]
}

stamp_matches() {
    [[ -f "$VERSION_STAMP" ]] || return 1
    grep -Fxq "SHERPA_ONNX_VERSION=${SHERPA_ONNX_VERSION}" "$VERSION_STAMP" &&
        grep -Fxq "ONNXRUNTIME_VERSION=${ONNXRUNTIME_VERSION}" "$VERSION_STAMP" &&
        grep -Fxq "XCFW_SHA256=${XCFW_SHA256}" "$VERSION_STAMP" &&
        grep -Fxq "ORT_SHA256=${ORT_SHA256}" "$VERSION_STAMP" &&
        grep -Fxq "WRAPPER_SHA256=${WRAPPER_SHA256}" "$VERSION_STAMP"
}

write_bridging_header() {
    local destination="$1"
    cat > "$destination" <<'EOF'
#ifndef SherpaOnnx_Bridging_Header_h
#define SherpaOnnx_Bridging_Header_h

#include "sherpa-onnx/c-api/c-api.h"

#endif
EOF
}

bridging_header_is_valid() {
    [[ -f "$WRAPPER_HEADER" ]] || return 1
    grep -Fxq '#ifndef SherpaOnnx_Bridging_Header_h' "$WRAPPER_HEADER" &&
        grep -Fxq '#include "sherpa-onnx/c-api/c-api.h"' "$WRAPPER_HEADER" &&
        grep -Fxq '#endif' "$WRAPPER_HEADER"
}

for tool in curl shasum awk grep lipo readlink tar unzip; do
    require_command "$tool"
done
[[ -x /usr/bin/python3 ]] || die "Missing /usr/bin/python3. Install the Xcode Command Line Tools or full Xcode first."

[[ "$FORCE_REFETCH" == "0" || "$FORCE_REFETCH" == "1" ]] ||
    die "SHERPA_ONNX_FORCE_REFETCH must be 0 or 1, got: ${FORCE_REFETCH}"
[[ "$SHERPA_ONNX_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "SHERPA_ONNX_VERSION must be a release tag such as v1.13.2, got: ${SHERPA_ONNX_VERSION}"

if [[ "$SHERPA_ONNX_VERSION" == "$DEFAULT_SHERPA_ONNX_VERSION" ]]; then
    XCFW_SHA256="$DEFAULT_XCFW_SHA256"
    ORT_SHA256="$DEFAULT_ORT_SHA256"
    WRAPPER_SHA256="$DEFAULT_WRAPPER_SHA256"
else
    XCFW_SHA256="${SHERPA_ONNX_XCFW_SHA256:-}"
    ORT_SHA256="${SHERPA_ONNX_ORT_SHA256:-}"
    WRAPPER_SHA256="${SHERPA_ONNX_WRAPPER_SHA256:-}"
    if [[ -z "$XCFW_SHA256" || -z "$ORT_SHA256" || -z "$WRAPPER_SHA256" ]]; then
        die "Overriding SHERPA_ONNX_VERSION requires SHERPA_ONNX_XCFW_SHA256, SHERPA_ONNX_ORT_SHA256, and SHERPA_ONNX_WRAPPER_SHA256. Update the Xcode project too if the release no longer uses ONNX Runtime ${ONNXRUNTIME_VERSION}."
    fi
fi

for checksum in "$XCFW_SHA256" "$ORT_SHA256" "$WRAPPER_SHA256"; do
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || die "Expected a lowercase 64-character SHA-256 value, got: ${checksum}"
done

wrapper_is_valid "$COMPILED_WRAPPER_SWIFT" "$WRAPPER_SHA256" ||
    die "The compiled SherpaOnnx bridge does not match ${SHERPA_ONNX_VERSION}. Update MeetMemo/SherpaOnnxBridge/SherpaOnnx.swift and its pinned checksum together."

XCFW_ASSET_NAME="sherpa-onnx-${SHERPA_ONNX_VERSION}-macos-xcframework-static.tar.bz2"
ORT_ASSET_NAME="sherpa-onnx-${SHERPA_ONNX_VERSION}-osx-universal2-shared-lib.tar.bz2"
RELEASE_BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_ONNX_VERSION}"
XCFW_URL="${RELEASE_BASE_URL}/${XCFW_ASSET_NAME}"
ORT_URL="${RELEASE_BASE_URL}/${ORT_ASSET_NAME}"
WRAPPER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/${SHERPA_ONNX_VERSION}/swift-api-examples/SherpaOnnx.swift"

NEED_XCFW=1
NEED_ORT=1
NEED_WRAPPER=1
if [[ "$FORCE_REFETCH" == "0" ]] && stamp_matches; then
    if xcframework_is_valid "$SHERPA_XCFW"; then NEED_XCFW=0; fi
    if onnxruntime_install_is_valid; then NEED_ORT=0; fi
    if wrapper_is_valid "$WRAPPER_SWIFT" "$WRAPPER_SHA256"; then NEED_WRAPPER=0; fi
fi

if [[ "$NEED_XCFW" -eq 0 && "$NEED_ORT" -eq 0 && "$NEED_WRAPPER" -eq 0 ]]; then
    if ! bridging_header_is_valid; then
        mkdir -p "$WRAPPER_DIR"
        HEADER_TEMP="$(mktemp)"
        write_bridging_header "$HEADER_TEMP"
        mv "$HEADER_TEMP" "$WRAPPER_HEADER"
    fi
    echo "✅ sherpa-onnx ${SHERPA_ONNX_VERSION} build dependencies are already verified."
    exit 0
fi

TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

STAGED_XCFW=""
STAGED_ORT=""
STAGED_WRAPPER=""

if [[ "$NEED_XCFW" -eq 1 ]]; then
    XCFW_ARCHIVE="${TEMP_ROOT}/${XCFW_ASSET_NAME}"
    XCFW_EXTRACT_DIR="${TEMP_ROOT}/xcframework"
    download_file "$XCFW_URL" "$XCFW_ARCHIVE" "$XCFW_ASSET_NAME"
    verify_sha256 "$XCFW_ARCHIVE" "$XCFW_SHA256" "$XCFW_ASSET_NAME"
    extract_archive "$XCFW_ARCHIVE" "$XCFW_EXTRACT_DIR"
    STAGED_XCFW="$(find "$XCFW_EXTRACT_DIR" -maxdepth 6 -type d -name sherpa-onnx.xcframework | head -n 1)"
    [[ -n "$STAGED_XCFW" ]] || die "${XCFW_ASSET_NAME} did not contain sherpa-onnx.xcframework."
    xcframework_is_valid "$STAGED_XCFW" ||
        die "The downloaded sherpa-onnx.xcframework is missing a macOS arm64 or x86_64 slice."
fi

if [[ "$NEED_ORT" -eq 1 ]]; then
    ORT_ARCHIVE="${TEMP_ROOT}/${ORT_ASSET_NAME}"
    ORT_EXTRACT_DIR="${TEMP_ROOT}/onnxruntime"
    download_file "$ORT_URL" "$ORT_ARCHIVE" "$ORT_ASSET_NAME"
    verify_sha256 "$ORT_ARCHIVE" "$ORT_SHA256" "$ORT_ASSET_NAME"
    extract_archive "$ORT_ARCHIVE" "$ORT_EXTRACT_DIR"
    STAGED_ORT="$(find "$ORT_EXTRACT_DIR" -path "*/lib/${ONNXRUNTIME_DYLIB_NAME}" -type f | head -n 1)"
    [[ -n "$STAGED_ORT" ]] ||
        die "${ORT_ASSET_NAME} did not contain ${ONNXRUNTIME_DYLIB_NAME}. This project is pinned to ONNX Runtime ${ONNXRUNTIME_VERSION}."
    onnxruntime_is_valid "$STAGED_ORT" ||
        die "${ONNXRUNTIME_DYLIB_NAME} is not a universal arm64/x86_64 dylib."
fi

if [[ "$NEED_WRAPPER" -eq 1 ]]; then
    STAGED_WRAPPER="${TEMP_ROOT}/SherpaOnnx.swift"
    download_file "$WRAPPER_URL" "$STAGED_WRAPPER" "SherpaOnnx.swift for ${SHERPA_ONNX_VERSION}"
    verify_sha256 "$STAGED_WRAPPER" "$WRAPPER_SHA256" "SherpaOnnx.swift"
fi

# Do not replace a working cache until every required download and validation has passed.
mkdir -p "$FRAMEWORKS_DIR" "$ONNXRUNTIME_LIB_DIR" "$WRAPPER_DIR"

if [[ "$NEED_XCFW" -eq 1 ]]; then
    rm -rf "$SHERPA_XCFW"
    mv "$STAGED_XCFW" "$SHERPA_XCFW"
fi

if [[ "$NEED_ORT" -eq 1 ]]; then
    rm -f "$ONNXRUNTIME_DYLIB" "$ONNXRUNTIME_SYMLINK"
    cp "$STAGED_ORT" "$ONNXRUNTIME_DYLIB"
    chmod 755 "$ONNXRUNTIME_DYLIB"
    ln -s "$ONNXRUNTIME_DYLIB_NAME" "$ONNXRUNTIME_SYMLINK"
fi

if [[ "$NEED_WRAPPER" -eq 1 ]]; then
    cp "$STAGED_WRAPPER" "$WRAPPER_SWIFT"
    chmod 644 "$WRAPPER_SWIFT"
fi

write_bridging_header "${TEMP_ROOT}/SherpaOnnx-Bridging-Header.h"
cp "${TEMP_ROOT}/SherpaOnnx-Bridging-Header.h" "$WRAPPER_HEADER"

cat > "${TEMP_ROOT}/version-stamp" <<EOF
SHERPA_ONNX_VERSION=${SHERPA_ONNX_VERSION}
ONNXRUNTIME_VERSION=${ONNXRUNTIME_VERSION}
XCFW_SHA256=${XCFW_SHA256}
ORT_SHA256=${ORT_SHA256}
WRAPPER_SHA256=${WRAPPER_SHA256}
EOF
mv "${TEMP_ROOT}/version-stamp" "$VERSION_STAMP"

xcframework_is_valid "$SHERPA_XCFW" || die "Installed sherpa-onnx.xcframework failed final validation."
onnxruntime_is_valid "$ONNXRUNTIME_DYLIB" || die "Installed ${ONNXRUNTIME_DYLIB_NAME} failed final validation."
onnxruntime_install_is_valid || die "Installed ONNX Runtime linker alias is missing or points to the wrong file."
wrapper_is_valid "$WRAPPER_SWIFT" "$WRAPPER_SHA256" || die "Installed SherpaOnnx.swift failed final validation."

echo "✅ Installed and verified sherpa-onnx build dependencies:"
echo "   sherpa-onnx: ${SHERPA_ONNX_VERSION}"
echo "   ONNX Runtime: ${ONNXRUNTIME_VERSION}"
echo "   ${SHERPA_XCFW}"
echo "   ${ONNXRUNTIME_DYLIB}"
echo "   ${WRAPPER_SWIFT}"
echo "   ${WRAPPER_HEADER}"
