#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build-xpi.sh"
POLICY_TEMPLATE="${ROOT_DIR}/deploy/firefox/policies.json"
DIST_XPI="${ROOT_DIR}/dist/contra.xpi"

TARGET_DIR="/opt/contra"
TARGET_XPI="${TARGET_DIR}/contra.xpi"
RELEASES_DIR="${TARGET_DIR}/releases"
POLICY_DIR="/etc/firefox/policies"
POLICY_FILE="${POLICY_DIR}/policies.json"
INSTALL_URL="file://${TARGET_XPI}"

run_build=true

usage() {
  cat <<'EOF'
Usage: scripts/install-firefox-policy.sh [--skip-build]

Installs contra.xpi and Firefox enterprise policies as root-owned files.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      run_build=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${run_build}" == true ]]; then
  "${BUILD_SCRIPT}"
fi

if [[ ! -f "${DIST_XPI}" ]]; then
  echo "XPI not found at ${DIST_XPI}" >&2
  echo "Run scripts/build-xpi.sh first or remove --skip-build." >&2
  exit 1
fi

if [[ ! -f "${POLICY_TEMPLATE}" ]]; then
  echo "Policy template not found at ${POLICY_TEMPLATE}" >&2
  exit 1
fi

policy_tmp_file="$(mktemp)"
trap 'rm -f "${policy_tmp_file}"' EXIT
sed "s|__CONTRA_INSTALL_URL__|${INSTALL_URL}|g" "${POLICY_TEMPLATE}" > "${policy_tmp_file}"

sudo install -d -o root -g root -m 0755 "${TARGET_DIR}"
sudo install -d -o root -g root -m 0755 "${RELEASES_DIR}"
sudo install -d -o root -g root -m 0755 "${POLICY_DIR}"

if sudo test -f "${TARGET_XPI}"; then
  backup_timestamp="$(date -u +%Y%m%d%H%M%S)"
  backup_path="${RELEASES_DIR}/contra-${backup_timestamp}.xpi"
  sudo cp "${TARGET_XPI}" "${backup_path}"
  sudo chmod 0444 "${backup_path}"
  echo "Backed up previous XPI to ${backup_path}"
fi

sudo install -o root -g root -m 0444 "${DIST_XPI}" "${TARGET_XPI}"
sudo install -o root -g root -m 0644 "${policy_tmp_file}" "${POLICY_FILE}"

cat <<EOF
Installed:
  XPI: ${TARGET_XPI}
  Policy: ${POLICY_FILE}

Next steps:
  1. Restart Firefox completely.
  2. Open about:policies and verify "Active" plus ExtensionSettings for contra@local.
  3. Run scripts/verify-firefox-policy.sh for filesystem checks.
EOF
