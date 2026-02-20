#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

filtered_args=()
for arg in "$@"; do
  case "${arg}" in
    --skip-build)
      echo "Warning: --skip-build is deprecated and ignored in AMO-first Hardcore Mode." >&2
      ;;
    *)
      filtered_args+=("${arg}")
      ;;
  esac
done

exec "${SCRIPT_DIR}/hardcore-install.sh" "${filtered_args[@]}"
