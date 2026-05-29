#!/usr/bin/env bash
#
# install_mac_local.sh
#
# Builds the Mbappe macOS target with development signing, copies the
# resulting `.app` into `/Applications`, and (optionally) launches it.
#
# Designed for fast on-this-Mac dev iteration. For distribution use
# `fastlane mac release` (Developer ID signed + notarized).
#
# Usage:
#   ./scripts/install_mac_local.sh             # build + copy to /Applications
#   ./scripts/install_mac_local.sh --launch    # build + copy + open the app
#   ./scripts/install_mac_local.sh --user      # install to ~/Applications instead
#   ./scripts/install_mac_local.sh --clean     # rm -rf the script's derived data first
#
# Requirements:
#   - Xcode installed
#   - xcodegen installed
#   - An "Apple Development" code-signing identity in the keychain
#   - A team id in project.local.yml (copy from project.local.example.yml)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="Mbappe"
PROJECT="Mbappe.xcodeproj"
DERIVED_DATA="${REPO_ROOT}/.derived-data-mac-local"
INSTALL_DIR="/Applications"
LAUNCH_AFTER_INSTALL=0

XCODEGEN_BIN=""
for candidate in \
    "/Users/mininic/.local/bin/xcodegen" \
    "/opt/homebrew/bin/xcodegen" \
    "/usr/local/bin/xcodegen" \
    "$(command -v xcodegen 2>/dev/null || true)"; do
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
        XCODEGEN_BIN="${candidate}"
        break
    fi
done

if [[ -z "${XCODEGEN_BIN}" ]]; then
    echo "error: xcodegen not found. Install via 'brew install xcodegen'." >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --launch)
            LAUNCH_AFTER_INSTALL=1
            shift
            ;;
        --user)
            INSTALL_DIR="${HOME}/Applications"
            shift
            ;;
        --clean)
            echo "==> Removing derived data: ${DERIVED_DATA}"
            rm -rf "${DERIVED_DATA}"
            shift
            ;;
        -h|--help)
            grep -E "^# " "$0" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "error: unknown flag '$1'" >&2
            exit 1
            ;;
    esac
done

echo "==> Verifying signing identities"
SIGN_LINES="$(security find-identity -v -p codesigning | grep -E 'Apple Development' || true)"
if [[ -z "${SIGN_LINES}" ]]; then
    echo "error: No 'Apple Development' code-signing identity found in your keychain." >&2
    echo "       Open Xcode > Settings > Accounts and create one for your team." >&2
    exit 1
fi
echo "${SIGN_LINES}"

LOCAL_OVERRIDE="${REPO_ROOT}/project.local.yml"
if [[ ! -f "${LOCAL_OVERRIDE}" ]]; then
    echo "error: ${LOCAL_OVERRIDE} not found. Create it with:"
    echo "       cp project.local.example.yml project.local.yml"
    echo "       and set DEVELOPMENT_TEAM to your team id."
    exit 1
fi

echo "==> Generating Xcode project (with project.local.yml)"
(cd "${REPO_ROOT}" && INCLUDE_PROJECT_LOCAL_YAML=1 "${XCODEGEN_BIN}" generate >/dev/null)

echo "==> Building ${SCHEME} for macOS (Debug, signed)"
xcodebuild \
    -project "${REPO_ROOT}/${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    -allowProvisioningUpdates \
    -quiet \
    build

APP_BUNDLE="${DERIVED_DATA}/Build/Products/Debug/Mbappe.app"
if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "error: expected app bundle not found at ${APP_BUNDLE}" >&2
    exit 1
fi

echo "==> Verifying signature"
codesign --verify --verbose=2 "${APP_BUNDLE}" || {
    echo "error: app failed signature verification" >&2
    exit 1
}

DEST="${INSTALL_DIR}/Mbappe.app"

# Quit any running Mbappe instance gracefully before replacing the bundle.
PROC_MATCH='Mbappe\.app/Contents/MacOS/Mbappe'
if pgrep -f "${PROC_MATCH}" >/dev/null 2>&1; then
    echo "==> Quitting running Mbappe"
    osascript -e 'tell application "Mbappe" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6; do
        pgrep -f "${PROC_MATCH}" >/dev/null 2>&1 || break
        sleep 0.5
    done
    if pgrep -f "${PROC_MATCH}" >/dev/null 2>&1; then
        pkill -f "${PROC_MATCH}" >/dev/null 2>&1 || true
        sleep 0.5
    fi
fi

echo "==> Installing to ${DEST}"
if [[ "${INSTALL_DIR}" == "/Applications" ]]; then
    if [[ -d "${DEST}" ]]; then
        sudo rm -rf "${DEST}"
    fi
    sudo cp -R "${APP_BUNDLE}" "${DEST}"
else
    mkdir -p "${INSTALL_DIR}"
    rm -rf "${DEST}"
    cp -R "${APP_BUNDLE}" "${DEST}"
fi

# Refresh Launch Services so the app appears in Spotlight immediately.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f -R -trusted "${DEST}" >/dev/null 2>&1 || true

echo "==> Installed: ${DEST}"

if [[ "${LAUNCH_AFTER_INSTALL}" == "1" ]]; then
    echo "==> Launching"
    open "${DEST}"
fi

echo "Done."
