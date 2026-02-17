#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/opt/contra"
TARGET_XPI="${TARGET_DIR}/contra.xpi"
RELEASES_DIR="${TARGET_DIR}/releases"
POLICY_FILE="/etc/firefox/policies/policies.json"

restore_backup=true
remove_managed_xpi=true

usage() {
  cat <<'EOF'
Usage: scripts/uninstall-firefox-policy.sh [--no-restore-backup] [--keep-managed-xpi]

Reverts Firefox policy lock changes:
  - Removes /etc/firefox/policies/policies.json
  - Restores latest backup from /opt/contra/releases if available (default)
  - Otherwise removes /opt/contra/contra.xpi (default)
EOF
}

latest_backup_path() {
  ls -1t "${RELEASES_DIR}"/contra-*.xpi 2>/dev/null | head -n 1 || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restore-backup)
      restore_backup=false
      shift
      ;;
    --keep-managed-xpi)
      remove_managed_xpi=false
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

if sudo test -f "${POLICY_FILE}"; then
  sudo rm -f "${POLICY_FILE}"
  echo "Removed ${POLICY_FILE}"
else
  echo "Policy file not found: ${POLICY_FILE}"
fi

if [[ "${restore_backup}" == true ]]; then
  backup_path="$(latest_backup_path)"
  if [[ -n "${backup_path}" ]]; then
    sudo install -o root -g root -m 0444 "${backup_path}" "${TARGET_XPI}"
    echo "Restored backup XPI from ${backup_path} to ${TARGET_XPI}"
  elif [[ "${remove_managed_xpi}" == true ]]; then
    sudo rm -f "${TARGET_XPI}"
    echo "No backup found. Removed managed XPI at ${TARGET_XPI}"
  else
    echo "No backup found. Managed XPI kept at ${TARGET_XPI}"
  fi
elif [[ "${remove_managed_xpi}" == true ]]; then
  sudo rm -f "${TARGET_XPI}"
  echo "Removed managed XPI at ${TARGET_XPI}"
else
  echo "Managed XPI kept at ${TARGET_XPI}"
fi

if sudo test -d "${TARGET_DIR}" && sudo test -z "$(sudo ls -A "${TARGET_DIR}" 2>/dev/null)"; then
  sudo rmdir "${TARGET_DIR}" || true
fi

cat <<'EOF'
Uninstall/revert complete.
Next steps:
  1. Restart Firefox completely.
  2. Open about:policies and confirm policies are no longer active.
EOF
