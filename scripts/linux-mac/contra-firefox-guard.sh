#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/firefox-profile-utils.sh
source "${SCRIPT_DIR}/lib/firefox-profile-utils.sh"

DEFAULT_ADDON_ID="contra@local"
DEFAULT_SOURCE_XPI="/home/mik/code/contra/dist/contra@local.xpi"
DEFAULT_MODE="enforce"
DEFAULT_SCAN_INTERVAL_SECONDS=2
ENV_FILE="/etc/contra/contra-firefox-guard.env"

addon_id="${DEFAULT_ADDON_ID}"
source_xpi="${DEFAULT_SOURCE_XPI}"
mode="${DEFAULT_MODE}"
scan_interval_seconds="${DEFAULT_SCAN_INTERVAL_SECONDS}"
daemon_mode=false
once_mode=false
check_only=false

usage() {
  cat <<'USAGE'
Usage: scripts/contra-firefox-guard.sh [options]

Guard Firefox startup against profile-bypass launches and inactive Contra profile state.

Options:
  --mode MODE              Guard mode: off|warn|enforce (default: enforce)
  --addon-id ID            Add-on ID to enforce (default: contra@local)
  --source-xpi PATH        Local source XPI path (default: /home/mik/code/contra/dist/contra@local.xpi)
  --scan-interval SEC      Daemon scan interval seconds (default: 2)
  --daemon                 Run continuously
  --once                   Run a single scan
  --check-only             Do not terminate processes; fail on violations
  -h, --help               Show help
USAGE
}

log_line() {
  printf '%s contra-firefox-guard: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
  fi
}

normalize_mode() {
  local raw_mode="${1,,}"
  case "${raw_mode}" in
    off|warn|enforce)
      printf '%s' "${raw_mode}"
      ;;
    *)
      printf '%s' "${DEFAULT_MODE}"
      ;;
  esac
}

firefox_processes() {
  local proc_dir=""
  local pid=""
  local exe_path=""
  local exe_name=""
  local cmdline=""

  for proc_dir in /proc/[0-9]*; do
    pid="${proc_dir##*/}"
    if [[ ! -r "${proc_dir}/cmdline" || ! -L "${proc_dir}/exe" ]]; then
      continue
    fi

    exe_path="$(readlink -f "${proc_dir}/exe" 2>/dev/null || true)"
    exe_name="$(basename "${exe_path}")"
    if [[ "${exe_name}" != "firefox" && "${exe_name}" != "firefox-bin" ]]; then
      continue
    fi

    cmdline="$(tr '\0' ' ' < "${proc_dir}/cmdline" 2>/dev/null || true)"
    if [[ -z "${cmdline}" ]]; then
      continue
    fi

    # Ignore non-primary subprocesses.
    if [[ "${cmdline}" == *" -contentproc "* || "${cmdline}" == *" -utility-sub-type "* ]]; then
      continue
    fi

    printf '%s\t%s\t%s\n' "${pid}" "${exe_path}" "${cmdline}"
  done
}

cmdline_uses_profile_switch() {
  local cmdline="$1"
  case " ${cmdline} " in
    *" -P "*|*" --ProfileManager "*|*" -profile "*|*" --profile "*)
      return 0
      ;;
  esac
  return 1
}

terminate_firefox_pid() {
  local pid="$1"
  if ! kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi
  kill -TERM "${pid}" 2>/dev/null || true
  sleep 0.4
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
  fi
}

collect_profile_violations() {
  local profile_dir=""
  local state=""
  local violations=()
  while IFS= read -r profile_dir; do
    if [[ -z "${profile_dir}" ]]; then
      continue
    fi
    state="$(contra_check_profile_addon_runtime_state "${profile_dir}" "${addon_id}")" || {
      violations+=("${profile_dir}|${state}")
      continue
    }
  done < <(contra_collect_firefox_profiles_unique)

  printf '%s\n' "${violations[@]}"
}

run_guard_scan() {
  local has_violations=false
  local kill_required=false
  local profile_violation=""
  local process_record=""
  local pid=""
  local exe_path=""
  local cmdline=""
  local reason=""
  local -a pids_to_kill=()

  if [[ "${mode}" == "off" ]]; then
    return 0
  fi

  if [[ ! -f "${source_xpi}" || ! -r "${source_xpi}" ]]; then
    has_violations=true
    kill_required=true
    log_line "Violation (source-xpi-unavailable): ${source_xpi}"
  fi

  while IFS= read -r process_record; do
    if [[ -z "${process_record}" ]]; then
      continue
    fi
    pid="${process_record%%$'\t'*}"
    process_record="${process_record#*$'\t'}"
    exe_path="${process_record%%$'\t'*}"
    cmdline="${process_record#*$'\t'}"

    if cmdline_uses_profile_switch "${cmdline}"; then
      has_violations=true
      kill_required=true
      reason="profile-switch-argument"
      log_line "Violation (${reason}): pid=${pid} exe=${exe_path} cmdline=${cmdline}"
      pids_to_kill+=("${pid}")
    fi
  done < <(firefox_processes)

  while IFS= read -r profile_violation; do
    if [[ -z "${profile_violation}" ]]; then
      continue
    fi
    has_violations=true
    kill_required=true
    log_line "Violation (profile-noncompliant): ${profile_violation}"
  done < <(collect_profile_violations)

  if [[ "${has_violations}" == false ]]; then
    return 0
  fi

  if [[ "${check_only}" == true ]]; then
    return 1
  fi

  if [[ "${mode}" == "warn" ]]; then
    log_line "Guard mode is warn; violations logged, no process termination."
    return 1
  fi

  if [[ "${kill_required}" == true ]]; then
    if [[ ${#pids_to_kill[@]} -eq 0 ]]; then
      while IFS= read -r process_record; do
        if [[ -z "${process_record}" ]]; then
          continue
        fi
        pids_to_kill+=("${process_record%%$'\t'*}")
      done < <(firefox_processes)
    fi

    local seen=""
    local kill_pid=""
    for kill_pid in "${pids_to_kill[@]}"; do
      if [[ ",${seen}," == *",${kill_pid},"* ]]; then
        continue
      fi
      seen+=",${kill_pid}"
      log_line "Terminating Firefox process due to guard violation: pid=${kill_pid}"
      terminate_firefox_pid "${kill_pid}"
    done
  fi

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --mode=*)
      mode="${1#*=}"
      shift
      ;;
    --addon-id)
      addon_id="${2:-}"
      shift 2
      ;;
    --addon-id=*)
      addon_id="${1#*=}"
      shift
      ;;
    --source-xpi)
      source_xpi="${2:-}"
      shift 2
      ;;
    --source-xpi=*)
      source_xpi="${1#*=}"
      shift
      ;;
    --scan-interval)
      scan_interval_seconds="${2:-}"
      shift 2
      ;;
    --scan-interval=*)
      scan_interval_seconds="${1#*=}"
      shift
      ;;
    --daemon)
      daemon_mode=true
      shift
      ;;
    --once)
      once_mode=true
      shift
      ;;
    --check-only)
      check_only=true
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

load_env_file

addon_id="${ADDON_ID:-${addon_id}}"
source_xpi="${SOURCE_XPI:-${source_xpi}}"
mode="$(normalize_mode "${GUARD_MODE:-${mode}}")"
scan_interval_seconds="${SCAN_INTERVAL_SECONDS:-${scan_interval_seconds}}"
scan_interval_seconds="${scan_interval_seconds//[^0-9]/}"
if [[ -z "${scan_interval_seconds}" ]]; then
  scan_interval_seconds="${DEFAULT_SCAN_INTERVAL_SECONDS}"
fi
if [[ "${scan_interval_seconds}" -lt 1 ]]; then
  scan_interval_seconds=1
fi

if [[ "${daemon_mode}" == false && "${once_mode}" == false ]]; then
  once_mode=true
fi

if [[ "${daemon_mode}" == true ]]; then
  log_line "Starting daemon mode (mode=${mode}, addon_id=${addon_id}, scan_interval=${scan_interval_seconds}s)."
  while true; do
    run_guard_scan || true
    sleep "${scan_interval_seconds}"
  done
fi

if run_guard_scan; then
  exit 0
fi

if [[ "${check_only}" == true || "${mode}" == "warn" ]]; then
  exit 1
fi

exit 0
