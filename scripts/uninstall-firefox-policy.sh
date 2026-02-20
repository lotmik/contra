#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

filtered_args=()
for arg in "$@"; do
  case "${arg}" in
    --no-restore-backup|--keep-managed-xpi)
      echo "Warning: ${arg} is deprecated and ignored in AMO-first Hardcore Mode." >&2
      ;;
    *)
      filtered_args+=("${arg}")
      ;;
  esac
done

exec "${SCRIPT_DIR}/hardcore-uninstall.sh" "${filtered_args[@]}"
