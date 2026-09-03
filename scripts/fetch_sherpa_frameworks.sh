#!/bin/bash
# Fetch the reproducible sherpa-onnx build dependencies into ./Frameworks/.
#
# The defaults are intentionally pinned. Upstream release assets and ONNX Runtime
# versions change independently, so following a moving "latest" release can make a
# clean checkout impossible to build. The xcframework release is used only as the
# canonical source of public headers/metadata: its bundled static library is replaced
# in staging with a library assembled from the official static-no-tts release. This
# prevents eSpeak-ng/Piper TTS objects from entering distributed application binaries.
# To test another sherpa-onnx release, callers must provide every expected SHA-256.

set -euo pipefail

readonly DEFAULT_SHERPA_ONNX_VERSION="v1.13.2"
readonly ONNXRUNTIME_VERSION="1.24.4"
readonly SHERPA_BUILD_PROFILE="static-no-tts"
readonly DEFAULT_HEADER_XCFW_SHA256="8756afb64ef7a1d612040c323e6f2cf707f90e703395413c79c572e37eddd65e"
readonly DEFAULT_NO_TTS_SHA256="da84dc0d6c7c09de1030caea2a2abadd1504bd66887100cf3af357df178c10ce"
readonly DEFAULT_ORT_SHA256="41e71d17eb9b4eb5ee28258d6c081d21d9061a41d826830be59c283c68326b02"
readonly DEFAULT_WRAPPER_SHA256="eb217f425b809fb17d97b1d214fa056c25796337e367390a24c4f04901d27540"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS_DIR="${REPO_ROOT}/Frameworks"
WRAPPER_DIR="${FRAMEWORKS_DIR}/swift-wrapper"
SHERPA_ONNX_VERSION="${SHERPA_ONNX_VERSION:-$DEFAULT_SHERPA_ONNX_VERSION}"
FORCE_REFETCH="${SHERPA_ONNX_FORCE_REFETCH:-0}"

SHERPA_XCFW="${FRAMEWORKS_DIR}/sherpa-onnx.xcframework"
SHERPA_LIBRARY="${SHERPA_XCFW}/macos-arm64_x86_64/libsherpa-onnx.a"
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

sherpa_library_is_no_tts() {
    local library="$1"
    local architectures
    [[ -f "$library" ]] || return 1
    architectures="$(lipo -archs "$library" 2>/dev/null)" || return 1
    [[ " ${architectures} " == *" arm64 "* && " ${architectures} " == *" x86_64 "* ]] || return 1

    # Verify the C APIs used by MeetMemo exist in both universal slices.
    local architecture symbol
    for architecture in arm64 x86_64; do
        for symbol in \
            SherpaOnnxCreateOfflineRecognizer \
            SherpaOnnxCreateVoiceActivityDetector \
            SherpaOnnxCreateSpeakerEmbeddingExtractor; do
            nm -gU -arch "$architecture" "$library" 2>/dev/null |
                grep -E "[[:space:]]T[[:space:]]_${symbol}$" >/dev/null || return 1
        done
    done

    # The no-TTS package retains inert public TTS declarations for API compatibility,
    # so match implementation/dependency fingerprints rather than the word "Tts".
    # In particular, do not match "Speaker", which contains the letters "espeak"
    # across a word boundary and is required for MeetMemo's diarization support.
    if nm "$library" 2>/dev/null |
        grep -Ei '(^|[[:space:]])(_?(AppendPhonemes|DecodePhonemes)|_?espeak(_ng)?_[[:alnum:]_]+|_?phonemize(_[[:alnum:]_]+)?)([[:space:]]|$)|piper[-_]phonemize' >/dev/null; then
        return 1
    fi
    if strings "$library" |
        grep -Ei 'piper[-_]phonemize|espeak-ng-data|libespeak|/espeak([/_.-]|$)|AppendPhonemes|DecodePhonemes' >/dev/null; then
        return 1
    fi
}

sherpa_xcframework_is_no_tts() {
    local framework="$1"
    xcframework_is_valid "$framework" &&
        sherpa_library_is_no_tts "${framework}/macos-arm64_x86_64/libsherpa-onnx.a"
}

build_no_tts_sherpa_library() {
    local extracted_root="$1"
    local destination="$2"
    local c_api_library library_dir
    c_api_library="$(find "$extracted_root" -type f -name libsherpa-onnx-c-api.a -print -quit)"
    [[ -n "$c_api_library" ]] ||
        die "The no-TTS archive did not contain libsherpa-onnx-c-api.a."
    library_dir="$(dirname "$c_api_library")"

    # Do not include libonnxruntime.a: MeetMemo deliberately embeds the pinned
    # ONNX Runtime dylib. Do not include PortAudio or the unused C++ wrapper either.
    # libtool safely combines the remaining universal archives into the existing
    # xcframework ABI/layout expected by both Xcode and the Command Line Tools build.
    local component_names=(
        libsherpa-onnx-c-api.a
        libsherpa-onnx-core.a
        libkaldi-native-fbank-core.a
        libkissfft-float.a
        libsherpa-onnx-kaldifst-core.a
        libsherpa-onnx-fst.a
        libsherpa-onnx-fstfar.a
        libkaldi-decoder-core.a
        libssentencepiece_core.a
    )
    local component component_path component_architectures
    local component_paths=()
    for component in "${component_names[@]}"; do
        component_path="${library_dir}/${component}"
        [[ -f "$component_path" ]] || die "The no-TTS archive is missing ${component}."
        component_architectures="$(lipo -archs "$component_path" 2>/dev/null)" ||
            die "Unable to inspect ${component}."
        [[ " ${component_architectures} " == *" arm64 "* && " ${component_architectures} " == *" x86_64 "* ]] ||
            die "${component} is not a universal arm64/x86_64 library."
        component_paths+=("$component_path")
    done

    # Apple libtool honors ZERO_AR_DATE and removes wall-clock timestamps from
    # the archive table, so identical pinned inputs yield byte-identical output.
    ZERO_AR_DATE=1 libtool -static -o "$destination" "${component_paths[@]}"
    sherpa_library_is_no_tts "$destination" ||
        die "The assembled sherpa-onnx library failed the ASR/no-TTS validation."
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
        grep -Fxq "SHERPA_BUILD_PROFILE=${SHERPA_BUILD_PROFILE}" "$VERSION_STAMP" &&
        grep -Fxq "HEADER_XCFW_SHA256=${HEADER_XCFW_SHA256}" "$VERSION_STAMP" &&
        grep -Fxq "NO_TTS_SHA256=${NO_TTS_SHA256}" "$VERSION_STAMP" &&
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

for tool in curl shasum awk grep lipo libtool nm strings readlink tar unzip; do
    require_command "$tool"
done
[[ -x /usr/bin/python3 ]] || die "Missing /usr/bin/python3. Install the Xcode Command Line Tools or full Xcode first."

[[ "$FORCE_REFETCH" == "0" || "$FORCE_REFETCH" == "1" ]] ||
    die "SHERPA_ONNX_FORCE_REFETCH must be 0 or 1, got: ${FORCE_REFETCH}"
[[ "$SHERPA_ONNX_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "SHERPA_ONNX_VERSION must be a release tag such as v1.13.2, got: ${SHERPA_ONNX_VERSION}"

if [[ "$SHERPA_ONNX_VERSION" == "$DEFAULT_SHERPA_ONNX_VERSION" ]]; then
    HEADER_XCFW_SHA256="$DEFAULT_HEADER_XCFW_SHA256"
    NO_TTS_SHA256="$DEFAULT_NO_TTS_SHA256"
    ORT_SHA256="$DEFAULT_ORT_SHA256"
    WRAPPER_SHA256="$DEFAULT_WRAPPER_SHA256"
else
    HEADER_XCFW_SHA256="${SHERPA_ONNX_HEADER_XCFW_SHA256:-}"
    NO_TTS_SHA256="${SHERPA_ONNX_NO_TTS_SHA256:-}"
    ORT_SHA256="${SHERPA_ONNX_ORT_SHA256:-}"
    WRAPPER_SHA256="${SHERPA_ONNX_WRAPPER_SHA256:-}"
    if [[ -z "$HEADER_XCFW_SHA256" || -z "$NO_TTS_SHA256" || -z "$ORT_SHA256" || -z "$WRAPPER_SHA256" ]]; then
        die "Overriding SHERPA_ONNX_VERSION requires SHERPA_ONNX_HEADER_XCFW_SHA256, SHERPA_ONNX_NO_TTS_SHA256, SHERPA_ONNX_ORT_SHA256, and SHERPA_ONNX_WRAPPER_SHA256. Update the Xcode project too if the release no longer uses ONNX Runtime ${ONNXRUNTIME_VERSION}."
    fi
fi

for checksum in "$HEADER_XCFW_SHA256" "$NO_TTS_SHA256" "$ORT_SHA256" "$WRAPPER_SHA256"; do
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || die "Expected a lowercase 64-character SHA-256 value, got: ${checksum}"
done

wrapper_is_valid "$COMPILED_WRAPPER_SWIFT" "$WRAPPER_SHA256" ||
    die "The compiled SherpaOnnx bridge does not match ${SHERPA_ONNX_VERSION}. Update MeetMemo/SherpaOnnxBridge/SherpaOnnx.swift and its pinned checksum together."

HEADER_XCFW_ASSET_NAME="sherpa-onnx-${SHERPA_ONNX_VERSION}-macos-xcframework-static.tar.bz2"
NO_TTS_ASSET_NAME="sherpa-onnx-${SHERPA_ONNX_VERSION}-osx-universal2-static-no-tts-lib.tar.bz2"
ORT_ASSET_NAME="sherpa-onnx-${SHERPA_ONNX_VERSION}-osx-universal2-shared-lib.tar.bz2"
RELEASE_BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_ONNX_VERSION}"
HEADER_XCFW_URL="${RELEASE_BASE_URL}/${HEADER_XCFW_ASSET_NAME}"
NO_TTS_URL="${RELEASE_BASE_URL}/${NO_TTS_ASSET_NAME}"
ORT_URL="${RELEASE_BASE_URL}/${ORT_ASSET_NAME}"
WRAPPER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/${SHERPA_ONNX_VERSION}/swift-api-examples/SherpaOnnx.swift"

NEED_XCFW=1
NEED_ORT=1
NEED_WRAPPER=1
if [[ "$FORCE_REFETCH" == "0" ]] && stamp_matches; then
    if sherpa_xcframework_is_no_tts "$SHERPA_XCFW"; then NEED_XCFW=0; fi
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
INSTALL_STAGE=""
FRAMEWORKS_BACKUP=""
SWAP_ACTIVE=0

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$SWAP_ACTIVE" -eq 1 ]]; then
        # A post-swap validation failed. Restore the exact previous cache instead
        # of leaving a partial dependency install behind.
        if [[ -d "$FRAMEWORKS_DIR" ]]; then
            FAILED_FRAMEWORKS="${TEMP_ROOT}/failed-frameworks"
            mv "$FRAMEWORKS_DIR" "$FAILED_FRAMEWORKS" 2>/dev/null || true
        fi
        if [[ -n "$FRAMEWORKS_BACKUP" && -d "$FRAMEWORKS_BACKUP" ]]; then
            if mv "$FRAMEWORKS_BACKUP" "$FRAMEWORKS_DIR" 2>/dev/null; then
                FRAMEWORKS_BACKUP=""
            else
                echo "⚠️  Automatic rollback failed; the previous cache is preserved at ${FRAMEWORKS_BACKUP}." >&2
            fi
        fi
    fi
    [[ -z "$INSTALL_STAGE" || ! -d "$INSTALL_STAGE" ]] || rm -rf "$INSTALL_STAGE"
    if [[ "$SWAP_ACTIVE" -eq 0 && -n "$FRAMEWORKS_BACKUP" && -d "$FRAMEWORKS_BACKUP" ]]; then
        rm -rf "$FRAMEWORKS_BACKUP"
    fi
    rm -rf "$TEMP_ROOT"
    exit "$status"
}
trap cleanup EXIT

STAGED_XCFW=""
STAGED_ORT=""
STAGED_WRAPPER=""

if [[ "$NEED_XCFW" -eq 1 ]]; then
    XCFW_ARCHIVE="${TEMP_ROOT}/${HEADER_XCFW_ASSET_NAME}"
    NO_TTS_ARCHIVE="${TEMP_ROOT}/${NO_TTS_ASSET_NAME}"
    XCFW_EXTRACT_DIR="${TEMP_ROOT}/xcframework"
    NO_TTS_EXTRACT_DIR="${TEMP_ROOT}/no-tts"
    download_file "$HEADER_XCFW_URL" "$XCFW_ARCHIVE" "$HEADER_XCFW_ASSET_NAME (headers only)"
    verify_sha256 "$XCFW_ARCHIVE" "$HEADER_XCFW_SHA256" "$HEADER_XCFW_ASSET_NAME"
    download_file "$NO_TTS_URL" "$NO_TTS_ARCHIVE" "$NO_TTS_ASSET_NAME"
    verify_sha256 "$NO_TTS_ARCHIVE" "$NO_TTS_SHA256" "$NO_TTS_ASSET_NAME"
    extract_archive "$XCFW_ARCHIVE" "$XCFW_EXTRACT_DIR"
    extract_archive "$NO_TTS_ARCHIVE" "$NO_TTS_EXTRACT_DIR"
    STAGED_XCFW="$(find "$XCFW_EXTRACT_DIR" -maxdepth 6 -type d -name sherpa-onnx.xcframework -print -quit)"
    [[ -n "$STAGED_XCFW" ]] || die "${HEADER_XCFW_ASSET_NAME} did not contain sherpa-onnx.xcframework."
    xcframework_is_valid "$STAGED_XCFW" ||
        die "The downloaded sherpa-onnx.xcframework is missing a macOS arm64 or x86_64 slice."
    STAGED_SHERPA_LIBRARY="${TEMP_ROOT}/libsherpa-onnx-no-tts.a"
    build_no_tts_sherpa_library "$NO_TTS_EXTRACT_DIR" "$STAGED_SHERPA_LIBRARY"
    cp "$STAGED_SHERPA_LIBRARY" "${STAGED_XCFW}/macos-arm64_x86_64/libsherpa-onnx.a"
    sherpa_xcframework_is_no_tts "$STAGED_XCFW" ||
        die "The staged sherpa-onnx.xcframework failed final no-TTS validation."
fi

if [[ "$NEED_ORT" -eq 1 ]]; then
    ORT_ARCHIVE="${TEMP_ROOT}/${ORT_ASSET_NAME}"
    ORT_EXTRACT_DIR="${TEMP_ROOT}/onnxruntime"
    download_file "$ORT_URL" "$ORT_ARCHIVE" "$ORT_ASSET_NAME"
    verify_sha256 "$ORT_ARCHIVE" "$ORT_SHA256" "$ORT_ASSET_NAME"
    extract_archive "$ORT_ARCHIVE" "$ORT_EXTRACT_DIR"
    STAGED_ORT="$(find "$ORT_EXTRACT_DIR" -path "*/lib/${ONNXRUNTIME_DYLIB_NAME}" -type f -print -quit)"
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

# Assemble and validate a complete sibling cache. The live Frameworks directory is
# not touched until every download, checksum, library merge, and symbol check passes.
# Keeping staging on the repository volume also makes the final directory renames
# atomic on APFS/HFS+ and permits an exact rollback if post-swap validation fails.
INSTALL_STAGE="$(mktemp -d "${REPO_ROOT}/.Frameworks-staging.XXXXXX")"
if [[ -d "$FRAMEWORKS_DIR" ]]; then
    cp -R "${FRAMEWORKS_DIR}/." "$INSTALL_STAGE/"
fi

if [[ "$NEED_XCFW" -eq 1 ]]; then
    rm -rf "${INSTALL_STAGE}/sherpa-onnx.xcframework"
    mv "$STAGED_XCFW" "${INSTALL_STAGE}/sherpa-onnx.xcframework"
fi

mkdir -p "${INSTALL_STAGE}/onnxruntime/lib" "${INSTALL_STAGE}/swift-wrapper"
if [[ "$NEED_ORT" -eq 1 ]]; then
    rm -f \
        "${INSTALL_STAGE}/onnxruntime/lib/${ONNXRUNTIME_DYLIB_NAME}" \
        "${INSTALL_STAGE}/onnxruntime/lib/libonnxruntime.dylib"
    cp "$STAGED_ORT" "${INSTALL_STAGE}/onnxruntime/lib/${ONNXRUNTIME_DYLIB_NAME}"
    chmod 755 "${INSTALL_STAGE}/onnxruntime/lib/${ONNXRUNTIME_DYLIB_NAME}"
    ln -s "$ONNXRUNTIME_DYLIB_NAME" "${INSTALL_STAGE}/onnxruntime/lib/libonnxruntime.dylib"
fi

if [[ "$NEED_WRAPPER" -eq 1 ]]; then
    cp "$STAGED_WRAPPER" "${INSTALL_STAGE}/swift-wrapper/SherpaOnnx.swift"
    chmod 644 "${INSTALL_STAGE}/swift-wrapper/SherpaOnnx.swift"
fi
write_bridging_header "${INSTALL_STAGE}/swift-wrapper/SherpaOnnx-Bridging-Header.h"

cat > "${INSTALL_STAGE}/.sherpa-onnx-version" <<EOF
SHERPA_ONNX_VERSION=${SHERPA_ONNX_VERSION}
ONNXRUNTIME_VERSION=${ONNXRUNTIME_VERSION}
SHERPA_BUILD_PROFILE=${SHERPA_BUILD_PROFILE}
HEADER_XCFW_SHA256=${HEADER_XCFW_SHA256}
NO_TTS_SHA256=${NO_TTS_SHA256}
ORT_SHA256=${ORT_SHA256}
WRAPPER_SHA256=${WRAPPER_SHA256}
EOF

STAGED_INSTALLED_XCFW="${INSTALL_STAGE}/sherpa-onnx.xcframework"
STAGED_INSTALLED_ORT="${INSTALL_STAGE}/onnxruntime/lib/${ONNXRUNTIME_DYLIB_NAME}"
STAGED_INSTALLED_ORT_LINK="${INSTALL_STAGE}/onnxruntime/lib/libonnxruntime.dylib"
STAGED_INSTALLED_WRAPPER="${INSTALL_STAGE}/swift-wrapper/SherpaOnnx.swift"
sherpa_xcframework_is_no_tts "$STAGED_INSTALLED_XCFW" ||
    die "The complete staged sherpa-onnx.xcframework failed ASR/no-TTS validation."
onnxruntime_is_valid "$STAGED_INSTALLED_ORT" ||
    die "The complete staged ${ONNXRUNTIME_DYLIB_NAME} failed validation."
[[ -L "$STAGED_INSTALLED_ORT_LINK" ]] &&
    [[ "$(readlink "$STAGED_INSTALLED_ORT_LINK")" == "$ONNXRUNTIME_DYLIB_NAME" ]] ||
    die "The complete staged ONNX Runtime linker alias is invalid."
wrapper_is_valid "$STAGED_INSTALLED_WRAPPER" "$WRAPPER_SHA256" ||
    die "The complete staged SherpaOnnx.swift failed validation."

FRAMEWORKS_BACKUP="${REPO_ROOT}/.Frameworks-backup.$$"
if [[ -d "$FRAMEWORKS_DIR" ]]; then
    mv "$FRAMEWORKS_DIR" "$FRAMEWORKS_BACKUP"
else
    FRAMEWORKS_BACKUP=""
fi
SWAP_ACTIVE=1
mv "$INSTALL_STAGE" "$FRAMEWORKS_DIR"
INSTALL_STAGE=""

sherpa_xcframework_is_no_tts "$SHERPA_XCFW" || die "Installed sherpa-onnx.xcframework failed final ASR/no-TTS validation."
onnxruntime_is_valid "$ONNXRUNTIME_DYLIB" || die "Installed ${ONNXRUNTIME_DYLIB_NAME} failed final validation."
onnxruntime_install_is_valid || die "Installed ONNX Runtime linker alias is missing or points to the wrong file."
wrapper_is_valid "$WRAPPER_SWIFT" "$WRAPPER_SHA256" || die "Installed SherpaOnnx.swift failed final validation."
SWAP_ACTIVE=0
if [[ -n "$FRAMEWORKS_BACKUP" && -d "$FRAMEWORKS_BACKUP" ]]; then
    rm -rf "$FRAMEWORKS_BACKUP"
fi
FRAMEWORKS_BACKUP=""

echo "✅ Installed and verified sherpa-onnx build dependencies:"
echo "   sherpa-onnx: ${SHERPA_ONNX_VERSION} (${SHERPA_BUILD_PROFILE})"
echo "   ONNX Runtime: ${ONNXRUNTIME_VERSION}"
echo "   ${SHERPA_XCFW}"
echo "   ${ONNXRUNTIME_DYLIB}"
echo "   ${WRAPPER_SWIFT}"
echo "   ${WRAPPER_HEADER}"
