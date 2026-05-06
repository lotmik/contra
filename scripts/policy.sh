#!/usr/bin/env bash
set -euo pipefail

REMOTE_SCRIPT_BASE="${CONTRA_POLICY_SCRIPT_BASE:-https://raw.githubusercontent.com/lotmik/contra/main/scripts}"

usage() {
  cat <<'USAGE'
Usage: scripts/policy.sh [options]
       scripts/policy.sh install [options]
       scripts/policy.sh uninstall [options]

Manage Contra Firefox enterprise policy installation.

Commands:
  no command   Toggle automatically: uninstall when installed, install otherwise
  install      Install and lock the Contra Firefox policy
  uninstall    Remove the Contra Firefox policy lock

Options are passed through to the selected install/uninstall implementation.
USAGE
}

is_supported_action() {
  case "${1:-}" in
    install|uninstall) return 0 ;;
    *) return 1 ;;
  esac
}

contra_normalize_linux_policy_file() {
  local input_path="$1"
  case "${input_path}" in
    */policies.json) printf '%s\n' "${input_path}"; return 0 ;;
    */distribution) printf '%s/policies.json\n' "${input_path}"; return 0 ;;
    */policies) printf '%s/policies.json\n' "${input_path}"; return 0 ;;
    */firefox|*/firefox-bin|*/firefox-esr) printf '%s/distribution/policies.json\n' "$(dirname "${input_path}")"; return 0 ;;
  esac

  if [[ -d "${input_path}" ]]; then
    [[ -d "${input_path}/distribution" ]] && { printf '%s/distribution/policies.json\n' "${input_path}"; return 0; }
    [[ -d "${input_path}/policies" ]] && { printf '%s/policies/policies.json\n' "${input_path}"; return 0; }
  fi

  return 1
}

contra_normalize_macos_policy_file() {
  local input_path="$1"
  local app_path=""

  case "${input_path}" in
    *.app) app_path="${input_path}" ;;
    */Contents/MacOS/firefox) app_path="${input_path%/Contents/MacOS/firefox}" ;;
    */Contents/Resources/distribution) app_path="${input_path%/Contents/Resources/distribution}" ;;
    */Contents/Resources/distribution/policies.json) app_path="${input_path%/Contents/Resources/distribution/policies.json}" ;;
    *) [[ -d "${input_path}/Contents/Resources" ]] && app_path="${input_path}" ;;
  esac

  [[ -n "${app_path}" ]] || return 1
  printf '%s/Contents/Resources/distribution/policies.json\n' "${app_path}"
}

contra_emit_known_linux_policy_files() {
  printf '%s\n' \
    '/etc/firefox/policies/policies.json' \
    '/etc/firefox-esr/policies/policies.json' \
    '/usr/lib/firefox/distribution/policies.json' \
    '/usr/lib64/firefox/distribution/policies.json' \
    '/usr/lib/firefox-esr/distribution/policies.json' \
    '/usr/lib64/firefox-esr/distribution/policies.json' \
    '/usr/local/lib/firefox/distribution/policies.json' \
    '/usr/local/lib64/firefox/distribution/policies.json' \
    '/opt/firefox/distribution/policies.json' \
    '/opt/firefox-esr/distribution/policies.json' \
    '/opt/firefox-developer-edition/distribution/policies.json' \
    '/opt/firefox-dev/distribution/policies.json' \
    '/snap/firefox/current/usr/lib/firefox/distribution/policies.json'

  local base
  for base in /etc/firefox*; do
    [[ -d "${base}" ]] && printf '%s\n' "${base}/policies/policies.json"
  done
  for base in /usr/lib/firefox* /usr/lib64/firefox* /usr/local/lib/firefox* /usr/local/firefox* /opt/firefox*; do
    [[ -d "${base}" ]] && printf '%s\n' "${base}/distribution/policies.json"
  done
}

contra_emit_known_macos_apps() {
  printf '%s\n' \
    '/Applications/Firefox.app' \
    '/Applications/Firefox Developer Edition.app' \
    '/Applications/Firefox Nightly.app' \
    '/Applications/Firefox Beta.app' \
    '/Applications/Firefox ESR.app' \
    "${HOME:-}/Applications/Firefox.app" \
    "${HOME:-}/Applications/Firefox Developer Edition.app" \
    "${HOME:-}/Applications/Firefox Nightly.app" \
    "${HOME:-}/Applications/Firefox Beta.app" \
    "${HOME:-}/Applications/Firefox ESR.app"
}

contra_collect_policy_files() {
  local os_name="$1"
  local firefox_path_override="$2"
  local policy_file_override="$3"
  local normalized_path=""
  local -a candidates=()
  local candidate install_root

  if [[ -n "${policy_file_override}" ]]; then
    printf '%s\n' "${policy_file_override}"
    return 0
  fi

  if [[ "${os_name}" == "Linux" ]]; then
    if [[ -n "${firefox_path_override}" ]]; then
      contra_normalize_linux_policy_file "${firefox_path_override}"
      return
    fi

    while IFS= read -r candidate; do
      [[ -z "${candidate}" ]] && continue
      if [[ -f "${candidate}" || -d "$(dirname "${candidate}")" ]]; then
        candidates+=("${candidate}")
        continue
      fi
      case "${candidate}" in
        */distribution/policies.json)
          install_root="${candidate%/distribution/policies.json}"
          [[ -d "${install_root}" ]] && candidates+=("${candidate}")
          ;;
        */policies/policies.json)
          install_root="${candidate%/policies/policies.json}"
          [[ -d "${install_root}" ]] && candidates+=("${candidate}")
          ;;
      esac
    done < <(contra_emit_known_linux_policy_files)

    [[ ${#candidates[@]} -eq 0 ]] && candidates+=('/etc/firefox/policies/policies.json')
    printf '%s\n' "${candidates[@]}" | awk 'NF && !seen[$0]++'
    return 0
  fi

  if [[ "${os_name}" == "Darwin" ]]; then
    if [[ -n "${firefox_path_override}" ]]; then
      contra_normalize_macos_policy_file "${firefox_path_override}"
      return
    fi

    while IFS= read -r candidate; do
      [[ -n "${candidate}" && -d "${candidate}" ]] && candidates+=("${candidate}/Contents/Resources/distribution/policies.json")
    done < <(contra_emit_known_macos_apps)

    printf '%s\n' "${candidates[@]}" | awk 'NF && !seen[$0]++'
    return 0
  fi

  return 1
}

is_perl_jsonpp_available() {
  command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1
}

policy_file_has_contra_entry() {
  local policy_file="$1"
  local addon_id="$2"

  [[ -f "${policy_file}" ]] || return 1

  if is_perl_jsonpp_available; then
    perl -MJSON::PP -e '
use strict;
use warnings;
my ($path, $addon_id) = @ARGV;
open my $fh, "<", $path or exit 1;
local $/;
my $raw = <$fh>;
close $fh;
my $data = eval { JSON::PP::decode_json($raw) };
exit 1 if $@ || ref($data) ne "HASH";
my $policies = $data->{policies};
exit 1 if ref($policies) ne "HASH";
my $settings = $policies->{ExtensionSettings};
exit 0 if ref($settings) eq "HASH" && exists $settings->{$addon_id};
my $managed = $policies->{"3rdparty"}->{Extensions}->{$addon_id};
exit 0 if ref($managed) eq "HASH" && exists $managed->{forceAdultBlock};
exit 1;
' "${policy_file}" "${addon_id}" >/dev/null 2>&1 && return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "${policy_file}" "${addon_id}" >/dev/null 2>&1 <<'PY' && return 0
import json
import sys

path, addon_id = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict):
    raise SystemExit(1)

policies = data.get("policies")
settings = policies.get("ExtensionSettings") if isinstance(policies, dict) else None
if isinstance(settings, dict) and addon_id in settings:
    raise SystemExit(0)

thirdparty = policies.get("3rdparty") if isinstance(policies, dict) else None
extensions = thirdparty.get("Extensions") if isinstance(thirdparty, dict) else None
managed = extensions.get(addon_id) if isinstance(extensions, dict) else None
if isinstance(managed, dict) and "forceAdultBlock" in managed:
    raise SystemExit(0)

raise SystemExit(1)
PY
  fi

  grep -Fq "\"${addon_id}\"" "${policy_file}"
}

detect_policy_action() {
  local addon_id="$1"
  local firefox_path="$2"
  local policy_file_override="$3"
  local os_name=""
  local policy_file=""

  os_name="$(uname -s)"
  while IFS= read -r policy_file; do
    if policy_file_has_contra_entry "${policy_file}" "${addon_id}"; then
      printf 'uninstall\n'
      return 0
    fi
  done < <(contra_collect_policy_files "${os_name}" "${firefox_path}" "${policy_file_override}" 2>/dev/null || true)

  printf 'install\n'
}

extract_common_option_values() {
  addon_id="contra@ltdmk"
  firefox_path=""
  policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --addon-id)
        addon_id="${2:-}"
        shift 2
        ;;
      --addon-id=*)
        addon_id="${1#*=}"
        shift
        ;;
      --firefox-path)
        firefox_path="${2:-}"
        shift 2
        ;;
      --firefox-path=*)
        firefox_path="${1#*=}"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
}

fetch_remote_script() {
  local script_name="$1"
  local script_url="${REMOTE_SCRIPT_BASE%/}/${script_name}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${script_url}"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO- "${script_url}"
    return
  fi

  echo "Need curl or wget to fetch ${script_url}." >&2
  return 1
}

action="${1:-}"
if [[ "${action}" == "-h" || "${action}" == "--help" ]]; then
  usage
  exit 0
fi

if is_supported_action "${action}"; then
  shift
elif [[ -n "${action}" && "${action}" != -* ]]; then
  usage >&2
  exit 1
else
  extract_common_option_values "$@"
  action="$(detect_policy_action "${addon_id}" "${firefox_path}" "${policy_file_override}")"
  if [[ "${action}" == "uninstall" ]]; then
    echo "Contra policy detected; running uninstall."
  else
    echo "Contra policy not detected; running install."
  fi
fi

script_name="${action}-policy.sh"
script_dir=""
script_source="${BASH_SOURCE[0]:-}"
if [[ -n "${script_source}" && -f "${script_source}" ]]; then
  script_dir="$(cd -- "$(dirname -- "${script_source}")" >/dev/null 2>&1 && pwd -P)"
fi

if [[ -n "${script_dir}" && -f "${script_dir}/${script_name}" ]]; then
  exec bash "${script_dir}/${script_name}" "$@"
fi

fetch_remote_script "${script_name}" | bash -s -- "$@"
