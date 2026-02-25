#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/etc/contra/contra-firefox-rescan.env"

DEFAULT_ADDON_ID="contra@local"
DEFAULT_INSTALL_URL="file:///home/mik/code/contra/dist/contra@local.xpi"
DEFAULT_GUARD_MODE="enforce"

addon_id="${DEFAULT_ADDON_ID}"
install_url="${DEFAULT_INSTALL_URL}"
guard_mode="${DEFAULT_GUARD_MODE}"
source_xpi="/home/mik/code/contra/dist/contra@local.xpi"

log_line() {
  printf '%s contra-firefox-rescan: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

addon_id="${ADDON_ID:-${addon_id}}"
install_url="${INSTALL_URL:-${install_url}}"
guard_mode="${GUARD_MODE:-${guard_mode}}"
source_xpi="${SOURCE_XPI:-${source_xpi}}"

log_line "Starting periodic rescan (addon_id=${addon_id}, guard_mode=${guard_mode})."

"${SCRIPT_DIR}/hardcore-install.sh" \
  --yes \
  --on-conflict merge \
  --addon-id "${addon_id}" \
  --install-url "${install_url}" \
  --guard-mode "${guard_mode}" \
  --profile-seed on \
  --source-xpi "${source_xpi}" \
  --internal-rescan-run

log_line "Periodic rescan completed."
