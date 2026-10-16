#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="${REPO_ROOT}/apps/macos"
CLI_MANIFEST="${REPO_ROOT}/apps/cli/Cargo.toml"
PROJECT_FILE="${MACOS_DIR}/Quotio.xcodeproj"
SCHEME="Quotio"
BUILD_DIR="${MACOS_DIR}/build"

usage() {
    cat <<EOF
Usage: $0 [--release|--debug|--package|--cli|--run|--clean] [extra args]

Build the Quotio app from the monorepo layout (apps/macos + apps/cli).

  (no args)   build the Release app executable for this machine, ad-hoc
              signed; no archive, ZIP, or DMG (default, same as --release)
  --release   same as no args
  --debug     build the Debug app instead
  --package   full release archive + ZIP/DMG via apps/macos/scripts/build_dmg.sh;
              remaining args are forwarded (e.g. --distribution --version X.Y.Z)
  --cli       build only the Rust CLI (apps/cli); pass --release for a release build
  --run       build Debug and launch via apps/macos/scripts/build_and_run.sh;
              remaining args are forwarded (--debug|--logs|--telemetry|--verify)
  --clean     remove ${BUILD_DIR}
  -h, --help  show this help

The Xcode build phase always compiles the Rust CLI helper (apps/cli) for the
active architecture and bundles it into the app, so cargo is required.

Outputs:
  Release app:  ${BUILD_DIR}/ReleaseDerivedData/Build/Products/Release/Quotio.app
  Debug app:    ${BUILD_DIR}/DebugDerivedData/Build/Products/Debug/Quotio.app
  Packages:     ${BUILD_DIR}/release/ (ZIP + DMG, via --package)
EOF
}

fail() {
    echo "error: $1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

CONFIGURATION="Release"
case "${1:-}" in
    ""|--release|release|-r)
        ;;
    --debug|debug|-d)
        CONFIGURATION="Debug"
        ;;
    --package|package|--dmg|dmg)
        shift
        exec "${MACOS_DIR}/scripts/build_dmg.sh" "$@"
        ;;
    --run|run)
        shift
        exec "${MACOS_DIR}/scripts/build_and_run.sh" "$@"
        ;;
    --cli|cli)
        shift
        require_command cargo
        exec cargo build --manifest-path "${CLI_MANIFEST}" --locked "$@"
        ;;
    --clean|clean)
        rm -rf "${BUILD_DIR}"
        echo "==> Removed ${BUILD_DIR}"
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        fail "unknown option: $1"
        ;;
esac

require_command xcodebuild
require_command cargo

DERIVED_DATA="${BUILD_DIR}/${CONFIGURATION}DerivedData"
CACHE_OWNER_FILE="${DERIVED_DATA}/.project-path"
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${SCHEME}.app"
LOG_FILE="${BUILD_DIR}/$(echo "${CONFIGURATION}" | tr '[:upper:]' '[:lower:]')-build.log"

mkdir -p "${DERIVED_DATA}"
if [ -f "${CACHE_OWNER_FILE}" ] && [ "$(cat "${CACHE_OWNER_FILE}")" != "${MACOS_DIR}" ]; then
    echo "==> Resetting DerivedData from another checkout"
    rm -rf "${DERIVED_DATA}"
    mkdir -p "${DERIVED_DATA}"
fi
printf '%s\n' "${MACOS_DIR}" > "${CACHE_OWNER_FILE}"

echo "==> Building ${SCHEME} (${CONFIGURATION})"
xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGN_IDENTITY="-" \
    build \
    2>&1 | tee "${LOG_FILE}"

[ -d "${APP_PATH}" ] || fail "built app not found at ${APP_PATH}"

echo "==> App: ${APP_PATH}"
echo "==> Build log: ${LOG_FILE}"
