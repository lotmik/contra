#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ADDON_ID="contra@ltdmk"
DEFAULT_INSTALL_URL="https://addons.mozilla.org/firefox/downloads/latest/contra-blocker/latest.xpi"

action="toggle"
addon_id="${DEFAULT_ADDON_ID}"
install_url="${DEFAULT_INSTALL_URL}"
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
skip_admin_check="${CONTRA_SKIP_ADMIN_CHECK:-0}"
yes_mode=false
on_conflict="merge"
on_conflict_explicit=false
force_adult_block=true
force_adult_block_explicit=false

usage() {
  cat <<'USAGE'
Usage: scripts/policy.sh [install|uninstall] [options]

Toggle Contra Firefox enterprise policy:
  - installs when Contra policy is not present
  - uninstalls when Contra policy is present

Options:
  --addon-id ID            Add-on ID to manage (default: contra@ltdmk)
  --install-url URL        Install URL (fixed to the published AMO latest endpoint)
  --firefox-path PATH      Firefox app/bin/install/policy path override
  --on-conflict MODE       Existing policies.json behavior: merge|overwrite|abort (default: merge)
  --adult                  Force-enable adult blocking via enterprise policy
  --no-adult               Do not set force adult policy flag
  --yes, -y                Non-interactive mode
  --profile-seed MODE      Accepted for compatibility; policy toggle does not seed profiles
  --source-xpi PATH        Accepted for compatibility; policy toggle does not seed profiles
  --remove-profile-seed    Accepted for compatibility; policy toggle does not touch profiles
  --keep-profile-seed      Accepted for compatibility; policy toggle does not touch profiles
  -h, --help               Show help
USAGE
}

is_supported_action() {
  case "${1:-}" in
    install|uninstall) return 0 ;;
    *) return 1 ;;
  esac
}

is_interactive_shell() {
  [[ -t 1 && -r /dev/tty && -w /dev/tty ]]
}

ask_yes_no_default_yes() {
  local prompt="$1"
  local answer=""

  if [[ "${yes_mode}" == true ]] || ! is_interactive_shell; then
    return 0
  fi

  while true; do
    if ! read -r -p "${prompt} [Y/n]: " answer < /dev/tty; then
      return 0
    fi
    answer="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
    case "${answer}" in
      ""|y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." >&2 ;;
    esac
  done
}

choose_conflict_mode_interactive() {
  local selected=""

  if [[ "${on_conflict_explicit}" == true || "${yes_mode}" == true ]] || ! is_interactive_shell; then
    printf '%s\n' "${on_conflict}"
    return 0
  fi

  while true; do
    if ! read -r -p "Existing policies.json found. Choose [m]erge, [o]verwrite, or [a]bort (default: merge): " selected < /dev/tty; then
      printf 'merge\n'
      return 0
    fi
    selected="$(printf '%s' "${selected}" | tr '[:upper:]' '[:lower:]')"
    case "${selected}" in
      ""|m|merge) printf 'merge\n'; return 0 ;;
      o|overwrite) printf 'overwrite\n'; return 0 ;;
      a|abort) printf 'abort\n'; return 0 ;;
      *) echo "Invalid selection: ${selected}" >&2 ;;
    esac
  done
}

json_escape() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//$'\n'/\\n}"
  raw="${raw//$'\r'/\\r}"
  raw="${raw//$'\t'/\\t}"
  printf '%s' "${raw}"
}

has_python3() {
  command -v python3 >/dev/null 2>&1
}

require_python3() {
  if has_python3; then
    return 0
  fi
  echo "python3 is required to safely merge or edit existing policies.json files." >&2
  return 1
}

install_python3_dependency() {
  local current_os="$1"

  case "${current_os}" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y python3
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3
      elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm python
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install python3
      else
        echo "No supported package manager found. Install python3 and rerun this script." >&2
        return 1
      fi
      ;;
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is not installed. Install Python 3 and rerun this script." >&2
        return 1
      fi
      if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        sudo -u "${SUDO_USER}" brew install python
      else
        brew install python
      fi
      ;;
    *)
      echo "Unsupported operating system for automatic python3 install: ${current_os}" >&2
      return 1
      ;;
  esac

  has_python3
}

prompt_uninstall_without_python() {
  local answer=""

  if [[ "${yes_mode}" == true ]] || ! is_interactive_shell; then
    echo "python3 is required for safe uninstall. Install python3 and rerun, or remove the backed-up policies.json manually if it contains only Contra policy entries." >&2
    return 1
  fi

  while true; do
    if ! read -r -p "python3 is unavailable. Choose [i]nstall python3 and continue, [r]emove whole policy files after backup, or [a]bort (default: install): " answer < /dev/tty; then
      printf 'install\n'
      return 0
    fi
    answer="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
    case "${answer}" in
      ""|i|install) printf 'install\n'; return 0 ;;
      r|remove) printf 'remove\n'; return 0 ;;
      a|abort) printf 'abort\n'; return 0 ;;
      *) echo "Invalid selection: ${answer}" >&2 ;;
    esac
  done
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
  local normalized_path=""
  local -a candidates=()
  local candidate install_root

  if [[ -n "${policy_file_override}" ]]; then
    printf '%s\n' "${policy_file_override}"
    return 0
  fi

  if [[ "${os_name}" == "Linux" ]]; then
    if [[ -n "${firefox_path}" ]]; then
      contra_normalize_linux_policy_file "${firefox_path}"
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
    if [[ -n "${firefox_path}" ]]; then
      contra_normalize_macos_policy_file "${firefox_path}"
      return
    fi

    while IFS= read -r candidate; do
      [[ -n "${candidate}" && -d "${candidate}" ]] && candidates+=("${candidate}/Contents/Resources/distribution/policies.json")
    done < <(contra_emit_known_macos_apps)

    [[ ${#candidates[@]} -gt 0 ]] || return 1
    printf '%s\n' "${candidates[@]}" | awk 'NF && !seen[$0]++'
    return 0
  fi

  echo "Unsupported operating system: ${os_name}" >&2
  return 1
}

render_target_policy_json_shell() {
  local output_file="$1"
  local addon_id_escaped install_url_escaped
  addon_id_escaped="$(json_escape "${addon_id}")"
  install_url_escaped="$(json_escape "${install_url}")"

  cat > "${output_file}" <<EOF_JSON
{
  "policies": {
    "ExtensionUpdate": true,
    "DisableSafeMode": true,
    "BlockAboutSupport": true,
    "BlockAboutProfiles": true,
    "Preferences": {
      "extensions.installDistroAddons": {
        "Value": true,
        "Status": "locked"
      }
    },
    "ExtensionSettings": {
      "${addon_id_escaped}": {
        "installation_mode": "force_installed",
        "install_url": "${install_url_escaped}",
        "private_browsing": true
      }
    }
EOF_JSON

  if [[ "${force_adult_block}" == true ]]; then
    cat >> "${output_file}" <<EOF_JSON
    ,
    "3rdparty": {
      "Extensions": {
        "${addon_id_escaped}": {
          "forceAdultBlock": true
        }
      }
    }
EOF_JSON
  fi

  cat >> "${output_file}" <<'EOF_JSON'
  }
}
EOF_JSON
}

policy_json_tool() {
  python3 - "$@" <<'PY'
import json
import os
import sys

op = sys.argv[1]

def load_policy(path):
    if not path or not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise SystemExit("top-level JSON must be an object")
    return data

def write_policy(path, data):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write("\n")

def policies_of(data):
    policies = data.get("policies")
    return policies if isinstance(policies, dict) else None

def has_contra(data, addon_id):
    policies = policies_of(data)
    if not policies:
        return False
    settings = policies.get("ExtensionSettings")
    if isinstance(settings, dict) and addon_id in settings:
        return True
    thirdparty = policies.get("3rdparty")
    extensions = thirdparty.get("Extensions") if isinstance(thirdparty, dict) else None
    managed = extensions.get(addon_id) if isinstance(extensions, dict) else None
    return isinstance(managed, dict) and "forceAdultBlock" in managed

def ensure_policies(data):
    policies = data.get("policies")
    if not isinstance(policies, dict):
        policies = {}
        data["policies"] = policies
    return policies

def prune_empty(data):
    policies = data.get("policies")
    if isinstance(policies, dict):
        thirdparty = policies.get("3rdparty")
        extensions = thirdparty.get("Extensions") if isinstance(thirdparty, dict) else None
        if isinstance(extensions, dict) and not extensions:
            thirdparty.pop("Extensions", None)
        if isinstance(thirdparty, dict) and not thirdparty:
            policies.pop("3rdparty", None)
        settings = policies.get("ExtensionSettings")
        if isinstance(settings, dict) and not settings:
            policies.pop("ExtensionSettings", None)
        prefs = policies.get("Preferences")
        if isinstance(prefs, dict) and not prefs:
            policies.pop("Preferences", None)
        if not policies:
            data.pop("policies", None)
    return data

def merge_policy(input_path, output_path, addon_id, install_url, force_adult, force_adult_explicit):
    data = load_policy(input_path)
    policies = ensure_policies(data)
    policies["ExtensionUpdate"] = True
    policies["DisableSafeMode"] = True
    policies["BlockAboutSupport"] = True
    policies["BlockAboutProfiles"] = True
    prefs = policies.setdefault("Preferences", {})
    if not isinstance(prefs, dict):
        prefs = {}
        policies["Preferences"] = prefs
    prefs["extensions.installDistroAddons"] = {"Value": True, "Status": "locked"}
    settings = policies.setdefault("ExtensionSettings", {})
    if not isinstance(settings, dict):
        settings = {}
        policies["ExtensionSettings"] = settings
    settings[addon_id] = {
        "installation_mode": "force_installed",
        "install_url": install_url,
        "private_browsing": True,
    }
    thirdparty = policies.setdefault("3rdparty", {})
    if not isinstance(thirdparty, dict):
        thirdparty = {}
        policies["3rdparty"] = thirdparty
    extensions = thirdparty.setdefault("Extensions", {})
    if not isinstance(extensions, dict):
        extensions = {}
        thirdparty["Extensions"] = extensions
    if force_adult == "true":
        managed = extensions.get(addon_id)
        if not isinstance(managed, dict):
            managed = {}
        managed["forceAdultBlock"] = True
        extensions[addon_id] = managed
    elif force_adult_explicit == "true":
        managed = extensions.get(addon_id)
        if isinstance(managed, dict):
            managed.pop("forceAdultBlock", None)
            if not managed:
                extensions.pop(addon_id, None)
    prune_empty(data)
    write_policy(output_path, data)

def remove_policy(input_path, output_path, addon_id):
    data = load_policy(input_path)
    removed = False
    policies = policies_of(data)
    prefs = None
    if isinstance(policies, dict):
        settings = policies.get("ExtensionSettings")
        if isinstance(settings, dict) and addon_id in settings:
            settings.pop(addon_id, None)
            removed = True
        thirdparty = policies.get("3rdparty")
        extensions = thirdparty.get("Extensions") if isinstance(thirdparty, dict) else None
        managed = extensions.get(addon_id) if isinstance(extensions, dict) else None
        if isinstance(managed, dict) and "forceAdultBlock" in managed:
            managed.pop("forceAdultBlock", None)
            removed = True
        if isinstance(managed, dict) and not managed and isinstance(extensions, dict):
            extensions.pop(addon_id, None)
        for key in ("ExtensionUpdate", "DisableSafeMode", "BlockAboutSupport", "BlockAboutProfiles"):
            if key in policies:
                policies.pop(key, None)
                removed = True
        prefs = policies.get("Preferences")
    if isinstance(prefs, dict) and "extensions.installDistroAddons" in prefs:
        prefs.pop("extensions.installDistroAddons", None)
        removed = True
    prune_empty(data)
    policies = policies_of(data)
    if isinstance(policies, dict) and set(policies.keys()) == {"ExtensionUpdate"} and policies.get("ExtensionUpdate") is True:
        policies.pop("ExtensionUpdate", None)
        removed = True
    prune_empty(data)
    if not data:
        print("EMPTY")
        return
    write_policy(output_path, data)
    print("REMOVED" if removed else "MISSING")

def verify_install(path, addon_id, install_url, expect_adult):
    data = load_policy(path)
    policies = policies_of(data)
    if not isinstance(policies, dict):
        raise SystemExit(1)
    for key in ("ExtensionUpdate", "DisableSafeMode", "BlockAboutSupport", "BlockAboutProfiles"):
        if not policies.get(key):
            raise SystemExit(1)
    pref = policies.get("Preferences", {}).get("extensions.installDistroAddons")
    if not isinstance(pref, dict) or not pref.get("Value") or pref.get("Status") != "locked":
        raise SystemExit(1)
    entry = policies.get("ExtensionSettings", {}).get(addon_id)
    if not isinstance(entry, dict):
        raise SystemExit(1)
    if entry.get("installation_mode") != "force_installed":
        raise SystemExit(1)
    if entry.get("install_url") != install_url:
        raise SystemExit(1)
    if not entry.get("private_browsing"):
        raise SystemExit(1)
    if expect_adult == "true":
        managed = policies.get("3rdparty", {}).get("Extensions", {}).get(addon_id)
        if not isinstance(managed, dict) or not managed.get("forceAdultBlock"):
            raise SystemExit(1)

def verify_uninstall(path, addon_id):
    if not os.path.exists(path):
        return
    data = load_policy(path)
    policies = policies_of(data)
    if not isinstance(policies, dict):
        return
    settings = policies.get("ExtensionSettings")
    if isinstance(settings, dict) and addon_id in settings:
        raise SystemExit(1)
    managed = policies.get("3rdparty", {}).get("Extensions", {}).get(addon_id)
    if isinstance(managed, dict) and "forceAdultBlock" in managed:
        raise SystemExit(1)
    for key in ("ExtensionUpdate", "DisableSafeMode", "BlockAboutSupport", "BlockAboutProfiles"):
        if key in policies:
            raise SystemExit(1)
    prefs = policies.get("Preferences")
    if isinstance(prefs, dict) and "extensions.installDistroAddons" in prefs:
        raise SystemExit(1)

if op == "has":
    data = load_policy(sys.argv[2])
    raise SystemExit(0 if has_contra(data, sys.argv[3]) else 1)
if op == "valid":
    load_policy(sys.argv[2])
    raise SystemExit(0)
if op == "merge":
    merge_policy(*sys.argv[2:8])
    raise SystemExit(0)
if op == "remove":
    remove_policy(*sys.argv[2:5])
    raise SystemExit(0)
if op == "verify-install":
    verify_install(*sys.argv[2:6])
    raise SystemExit(0)
if op == "verify-uninstall":
    verify_uninstall(*sys.argv[2:4])
    raise SystemExit(0)
raise SystemExit(f"unknown op: {op}")
PY
}

policy_file_has_contra_entry() {
  local policy_file="$1"
  [[ -f "${policy_file}" ]] || return 1
  if has_python3; then
    policy_json_tool has "${policy_file}" "${addon_id}" >/dev/null 2>&1 && return 0
  fi
  grep -Fq "\"${addon_id}\"" "${policy_file}"
}

policy_json_valid() {
  local policy_file="$1"
  has_python3 && policy_json_tool valid "${policy_file}" >/dev/null 2>&1
}

backup_policy_file() {
  local policy_file="$1"
  local policy_index="$2"
  local backup_dir backup_path timestamp

  [[ -f "${policy_file}" ]] || return 0
  backup_dir="$(dirname "${policy_file}")/contra-policy-backups"
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  backup_path="${backup_dir}/policies-${timestamp}-${policy_index}.json"
  install -d -m 0755 "${backup_dir}"
  cp "${policy_file}" "${backup_path}"
  chmod 0644 "${backup_path}"
}

install_policy_file() {
  local policy_file="$1"
  local policy_index="$2"
  local policy_dir final_policy conflict_mode

  policy_dir="$(dirname "${policy_file}")"
  final_policy="${work_dir}/policy-install-${policy_index}.json"
  backup_policy_file "${policy_file}" "${policy_index}"

  if [[ -f "${policy_file}" ]]; then
    conflict_mode="$(choose_conflict_mode_interactive)"
    case "${conflict_mode}" in
      abort) echo "Install aborted for ${policy_file}."; return 2 ;;
      overwrite)
        render_target_policy_json_shell "${final_policy}"
        ;;
      merge)
        if require_python3 && policy_json_valid "${policy_file}"; then
          policy_json_tool merge "${policy_file}" "${final_policy}" "${addon_id}" "${install_url}" "${force_adult_block}" "${force_adult_block_explicit}"
        else
          echo "Cannot merge ${policy_file}; writing strict Contra policy template instead." >&2
          render_target_policy_json_shell "${final_policy}"
        fi
        ;;
    esac
  else
    render_target_policy_json_shell "${final_policy}"
  fi

  install -d -m 0755 "${policy_dir}"
  install -m 0644 "${final_policy}" "${policy_file}"
  if has_python3; then
    policy_json_tool verify-install "${policy_file}" "${addon_id}" "${install_url}" "${force_adult_block}" >/dev/null
  else
    grep -Fq "\"${addon_id}\"" "${policy_file}"
  fi
}

uninstall_policy_file() {
  local policy_file="$1"
  local policy_index="$2"
  local updated_policy remove_status

  [[ -f "${policy_file}" ]] || return 0
  updated_policy="${work_dir}/policy-uninstall-${policy_index}.json"
  backup_policy_file "${policy_file}" "${policy_index}"

  if ! policy_json_valid "${policy_file}"; then
    echo "Invalid or unparsable JSON in ${policy_file}; removing whole file after backup." >&2
    rm -f "${policy_file}"
    return 0
  fi

  remove_status="$(policy_json_tool remove "${policy_file}" "${updated_policy}" "${addon_id}")"
  case "${remove_status}" in
    EMPTY)
      rm -f "${policy_file}"
      ;;
    REMOVED|MISSING)
      install -m 0644 "${updated_policy}" "${policy_file}"
      ;;
    *)
      echo "Unexpected uninstall status for ${policy_file}: ${remove_status}" >&2
      return 1
      ;;
  esac

  policy_json_tool verify-uninstall "${policy_file}" "${addon_id}" >/dev/null
}

remove_whole_policy_files_after_backup() {
  local index=0
  local removed=0
  local skipped=0
  local policy_file

  for policy_file in "${policy_files[@]}"; do
    index=$((index + 1))
    if [[ -f "${policy_file}" ]] && policy_file_has_contra_entry "${policy_file}"; then
      backup_policy_file "${policy_file}" "${index}"
      rm -f "${policy_file}"
      echo "Removed whole policy file after backup: ${policy_file}"
      removed=$((removed + 1))
    else
      skipped=$((skipped + 1))
    fi
  done

  echo "Emergency uninstall summary: removed=${removed}, skipped=${skipped}"
  [[ "${removed}" -gt 0 ]]
}

handle_uninstall_without_python() {
  local strategy=""

  while true; do
    if ! strategy="$(prompt_uninstall_without_python)"; then
      return 1
    fi
    case "${strategy}" in
      install)
        if install_python3_dependency "${os_name}"; then
          echo "python3 is available; continuing safe uninstall."
          return 2
        fi
        echo "python3 installation failed or python3 is still unavailable." >&2
        ;;
      remove)
        remove_whole_policy_files_after_backup
        return
        ;;
      abort)
        echo "Uninstall aborted."
        return 1
        ;;
    esac
  done
}

detect_policy_action() {
  local policy_file
  while IFS= read -r policy_file; do
    if policy_file_has_contra_entry "${policy_file}"; then
      printf 'uninstall\n'
      return 0
    fi
  done < <(printf '%s\n' "${policy_files[@]}")
  printf 'install\n'
}

install_policy() {
  local index=0
  local failures=0
  local installed=0
  local policy_file

  if [[ "${force_adult_block_explicit}" == false ]]; then
    if ask_yes_no_default_yes "Enable forced adult blocking"; then
      force_adult_block=true
    else
      force_adult_block=false
    fi
  fi

  for policy_file in "${policy_files[@]}"; do
    index=$((index + 1))
    echo "Installing policy: ${policy_file}"
    if install_policy_file "${policy_file}" "${index}"; then
      installed=$((installed + 1))
    else
      failures=$((failures + 1))
    fi
  done

  echo "Install summary: installed=${installed}, failed=${failures}"
  [[ "${failures}" -eq 0 ]]
}

uninstall_policy() {
  local index=0
  local failures=0
  local removed=0
  local fallback_status=0
  local policy_file

  if ! has_python3; then
    handle_uninstall_without_python || fallback_status=$?
    if [[ "${fallback_status}" -eq 0 ]]; then
      return 0
    fi
    if [[ "${fallback_status}" -eq 2 ]] && has_python3; then
      :
    else
      return 1
    fi
  fi

  for policy_file in "${policy_files[@]}"; do
    index=$((index + 1))
    echo "Uninstalling policy: ${policy_file}"
    if uninstall_policy_file "${policy_file}" "${index}"; then
      removed=$((removed + 1))
    else
      failures=$((failures + 1))
    fi
  done

  echo "Uninstall summary: processed=${removed}, failed=${failures}"
  [[ "${failures}" -eq 0 ]]
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "${1:-}" in
      -h|--help)
        usage
        exit 0
        ;;
    esac
  fi

  if [[ $# -gt 0 ]] && is_supported_action "${1:-}"; then
    action="$1"
    shift
  elif [[ $# -gt 0 && "${1:-}" != -* ]]; then
    echo "Unknown command: $1" >&2
    usage >&2
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --addon-id) addon_id="${2:-}"; shift 2 ;;
      --addon-id=*) addon_id="${1#*=}"; shift ;;
      --install-url) install_url="${2:-}"; shift 2 ;;
      --install-url=*) install_url="${1#*=}"; shift ;;
      --firefox-path) firefox_path="${2:-}"; shift 2 ;;
      --firefox-path=*) firefox_path="${1#*=}"; shift ;;
      --on-conflict) on_conflict="${2:-}"; on_conflict_explicit=true; shift 2 ;;
      --on-conflict=*) on_conflict="${1#*=}"; on_conflict_explicit=true; shift ;;
      --adult) force_adult_block=true; force_adult_block_explicit=true; shift ;;
      --no-adult) force_adult_block=false; force_adult_block_explicit=true; shift ;;
      --yes|-y) yes_mode=true; shift ;;
      --profile-seed) shift 2 ;;
      --profile-seed=*) shift ;;
      --source-xpi) shift 2 ;;
      --source-xpi=*) shift ;;
      --remove-profile-seed|--keep-profile-seed) shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

parse_args "$@"

[[ -n "${addon_id}" ]] || { echo "--addon-id cannot be empty." >&2; exit 1; }
[[ "${install_url}" == "${DEFAULT_INSTALL_URL}" ]] || { echo "--install-url is fixed to ${DEFAULT_INSTALL_URL}" >&2; exit 1; }

on_conflict="$(printf '%s' "${on_conflict}" | tr '[:upper:]' '[:lower:]')"
case "${on_conflict}" in
  merge|overwrite|abort) ;;
  *) echo "Invalid --on-conflict value: ${on_conflict}. Use merge|overwrite|abort." >&2; exit 1 ;;
esac

if [[ "${skip_admin_check}" != "1" && "${EUID}" -ne 0 ]]; then
  echo "Run as admin, for example: sudo bash scripts/policy.sh" >&2
  exit 1
fi

os_name="$(uname -s)"
policy_files=()
while IFS= read -r policy_file; do
  policy_files+=("${policy_file}")
done < <(contra_collect_policy_files "${os_name}")
[[ ${#policy_files[@]} -gt 0 ]] || { echo "Could not determine any Firefox policy file targets." >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

requested_action="${action}"
if [[ "${action}" == "toggle" ]]; then
  action="$(detect_policy_action)"
fi

case "${action}" in
  install)
    if [[ "${requested_action}" == "toggle" ]]; then
      echo "Contra policy not detected; installing."
    else
      echo "Installing Contra policy."
    fi
    install_policy
    ;;
  uninstall)
    if [[ "${requested_action}" == "toggle" ]]; then
      echo "Contra policy detected; uninstalling."
    else
      echo "Uninstalling Contra policy."
    fi
    uninstall_policy
    ;;
  *)
    echo "Unknown action: ${action}" >&2
    exit 1
    ;;
esac
