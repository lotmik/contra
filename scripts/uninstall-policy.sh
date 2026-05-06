#!/usr/bin/env bash
set -euo pipefail

# Script Summary:
# - Detects Firefox policy locations (Linux/macOS), then creates backups before edits.
# - Removes only Contra-managed enterprise policy keys while preserving unrelated keys.
# - Optionally removes profile-seeded XPI files.
# - Prints concise progress + final deduplicated policy summary.
# Base constants and mutable runtime state.
# Keeping these declarations centralized makes runtime behavior easy to audit.
DEFAULT_ADDON_ID="contra@ltdmk"
addon_id="${DEFAULT_ADDON_ID}"
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
skip_admin_check="${CONTRA_SKIP_ADMIN_CHECK:-0}"
remove_profile_seed=true
yes_mode=false
json_fallback_mode="edit"

# Prints CLI usage and available flags.
# Behavior:
# - Emits full command synopsis and option list to stdout.
usage() {
  cat <<'USAGE'
Usage: scripts/uninstall-policy.sh [options]

Remove Contra Firefox enterprise policy lock while preserving unrelated policies.

Options:
  --addon-id ID            Add-on ID to unlock (default: contra@ltdmk)
  --firefox-path PATH      Optional Firefox app/bin/install path to include (default: auto-detect)
  --remove-profile-seed    Remove profile-seeded extension files (default: true)
  --keep-profile-seed      Keep profile-seeded extension files
  --yes, -y                Non-interactive mode (uses python3 fallback when Perl is missing)
  -h, --help               Show help
USAGE
}

# Emits common Linux Firefox policies.json targets.
# Output:
# - Candidate policy file paths (one per line).
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

# Emits common macOS Firefox app bundle paths.
# Output:
# - Candidate app bundle roots (one per line).
contra_emit_known_macos_apps() {
  printf '%s\n' \
    '/Applications/Firefox.app' \
    '/Applications/Firefox Developer Edition.app' \
    '/Applications/Firefox Nightly.app' \
    '/Applications/Firefox Beta.app' \
    '/Applications/Firefox ESR.app' \
    "${HOME}/Applications/Firefox.app" \
    "${HOME}/Applications/Firefox Developer Edition.app" \
    "${HOME}/Applications/Firefox Nightly.app" \
    "${HOME}/Applications/Firefox Beta.app" \
    "${HOME}/Applications/Firefox ESR.app"
}

# Normalizes Linux inputs into a policies.json file path.
# Input:
# - $1: user-provided Linux path to firefox binary/install/policy.
# Output:
# - Normalized policies.json path on success.
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

# Normalizes macOS inputs into a policies.json file path.
# Input:
# - $1: `.app` path or nested bundle path on macOS.
# Output:
# - Normalized policies.json path on success.
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

# Collects unique policy-file targets for the current OS.
# Input:
# - $1: OS name, $2: optional firefox-path override, $3: explicit policy override.
# Output:
# - Deduplicated policy targets, one per line.
contra_collect_policy_files() {
  local os_name="$1"
  local firefox_path_override="${2:-}"
  local policy_file_override_local="${3:-}"
  local normalized_path=""
  local -a candidates=()
  local candidate install_root

  if [[ -n "${policy_file_override_local}" ]]; then
    printf '%s\n' "${policy_file_override_local}"
    return 0
  fi

  if [[ "${os_name}" == "Linux" ]]; then
    if [[ -n "${firefox_path_override}" ]]; then
      if ! normalized_path="$(contra_normalize_linux_policy_file "${firefox_path_override}")"; then
        echo "Invalid --firefox-path for Linux: ${firefox_path_override}" >&2
        return 1
      fi
      candidates+=("${normalized_path}")
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
      if ! normalized_path="$(contra_normalize_macos_policy_file "${firefox_path_override}")"; then
        echo "Invalid --firefox-path for macOS: ${firefox_path_override}" >&2
        return 1
      fi
      candidates+=("${normalized_path}")
    else
      while IFS= read -r candidate; do
        [[ -n "${candidate}" && -d "${candidate}" ]] && candidates+=("${candidate}/Contents/Resources/distribution/policies.json")
      done < <(contra_emit_known_macos_apps)
    fi
    [[ ${#candidates[@]} -gt 0 ]] || { echo "Could not locate Firefox app bundle(s)." >&2; return 1; }
    printf '%s\n' "${candidates[@]}" | awk 'NF && !seen[$0]++'
    return 0
  fi

  echo "Unsupported operating system: ${os_name}" >&2
  return 1
}

# Scans home directories for Firefox profile roots.
# Output:
# - Existing profile root directories under common home paths.
contra_emit_profile_roots_from_homes() {
  local home_dir
  for home_dir in /home/* /root; do
    [[ -d "${home_dir}/.mozilla/firefox" ]] && printf '%s\n' "${home_dir}/.mozilla/firefox"
  done
}

# Builds candidate Firefox profile roots in priority order.
# Output:
# - Profile roots in deterministic lookup order.
# Notes:
# - Custom roots from `CONTRA_FIREFOX_PROFILE_ROOTS` are checked first.
contra_emit_profile_roots() {
  local sudo_home=""
  local sudo_user_home=""
  local custom_roots="${CONTRA_FIREFOX_PROFILE_ROOTS:-}"
  local item

  if [[ -n "${custom_roots}" ]]; then
    IFS=':' read -r -a _custom_root_items <<< "${custom_roots}"
    for item in "${_custom_root_items[@]}"; do
      [[ -n "${item}" ]] && printf '%s\n' "${item}"
    done
  fi
  if [[ -n "${SUDO_USER:-}" ]]; then
    if command -v getent >/dev/null 2>&1; then
      sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | awk -F: 'NR==1 {print $6}')"
    fi
    [[ -n "${sudo_home}" ]] && printf '%s\n' "${sudo_home}/.mozilla/firefox"
  fi
  [[ -n "${HOME:-}" ]] && printf '%s\n' "${HOME}/.mozilla/firefox"
  if command -v getent >/dev/null 2>&1; then
    sudo_user_home="$(getent passwd "$(id -un)" 2>/dev/null | awk -F: 'NR==1 {print $6}')"
  fi
  [[ -n "${sudo_user_home}" ]] && printf '%s\n' "${sudo_user_home}/.mozilla/firefox"
  contra_emit_profile_roots_from_homes
}

# Returns unique existing profile-root directories.
# Output:
# - Deduplicated profile roots that currently exist.
contra_collect_profile_roots() {
  contra_emit_profile_roots | awk 'NF && !seen[$0]++ && system("[ -d \"" $0 "\" ]") == 0'
}

# Reads profiles.ini and emits resolved profile paths.
# Input:
# - $1: profile root path.
# Output:
# - Resolved profile directories extracted from profiles.ini.
contra_emit_profiles_from_profiles_ini() {
  local profile_root="$1"
  local ini_file="${profile_root}/profiles.ini"
  local path_value=""
  local resolved=""
  [[ ! -f "${ini_file}" ]] && return 0
  while IFS= read -r line; do
    case "${line}" in
      Path=*)
        path_value="${line#Path=}"
        [[ -z "${path_value}" ]] && continue
        if [[ "${path_value}" == /* ]]; then
          resolved="${path_value}"
        else
          resolved="${profile_root}/${path_value}"
        fi
        printf '%s\n' "${resolved}"
        ;;
    esac
  done < "${ini_file}"
}

# Finds profile dirs by scanning profile-root contents.
# Input:
# - $1: profile root path.
# Output:
# - Candidate profile directories inferred from expected profile files.
contra_emit_profiles_from_root_scan() {
  local profile_root="$1"
  local profile_dir base_name
  for profile_dir in "${profile_root}"/*; do
    [[ -d "${profile_dir}" ]] || continue
    base_name="$(basename "${profile_dir}")"
    case "${base_name}" in
      "Crash Reports"|"Pending Pings"|"Profile Groups") continue ;;
    esac
    [[ -f "${profile_dir}/prefs.js" || -f "${profile_dir}/times.json" || -f "${profile_dir}/extensions.json" ]] && printf '%s\n' "${profile_dir}"
  done
}

# Collects profile directories from all discovered roots.
# Output:
# - Raw list of profile directories discovered from all profile roots.
contra_collect_firefox_profiles() {
  local profile_root
  while IFS= read -r profile_root; do
    [[ -z "${profile_root}" || ! -d "${profile_root}" ]] && continue
    contra_emit_profiles_from_profiles_ini "${profile_root}"
    contra_emit_profiles_from_root_scan "${profile_root}"
  done < <(contra_collect_profile_roots)
}

# Returns unique existing Firefox profile directories.
# Output:
# - Deduplicated profile directories that exist.
contra_collect_firefox_profiles_unique() {
  contra_collect_firefox_profiles | awk 'NF && !seen[$0]++ && system("[ -d \"" $0 "\" ]") == 0'
}

# Builds managed extension XPI path for a profile.
# Input:
# - $1: profile directory, $2: addon id.
# Output:
# - Path to managed profile XPI location.
contra_profile_extension_path() {
  local profile_dir="$1"
  local addon_id_local="$2"
  printf '%s/extensions/%s.xpi' "${profile_dir}" "${addon_id_local}"
}

# Removes managed XPI from one Firefox profile if present.
# Input:
# - $1: profile directory, $2: addon id.
# Output:
# - status tuple: `removed|...`, `missing|...`, or `failed|...`.
contra_remove_profile_xpi() {
  local profile_dir="$1"
  local addon_id_local="$2"
  local extension_file=""
  extension_file="$(contra_profile_extension_path "${profile_dir}" "${addon_id_local}")"
  [[ -d "${profile_dir}" ]] || { printf 'failed|%s|profile directory missing\n' "${profile_dir}"; return 1; }
  [[ -e "${extension_file}" ]] || { printf 'missing|%s|%s\n' "${profile_dir}" "${extension_file}"; return 0; }
  rm -f "${extension_file}" || { printf 'failed|%s|could not remove extension file: %s\n' "${profile_dir}" "${extension_file}"; return 1; }
  printf 'removed|%s|%s\n' "${profile_dir}" "${extension_file}"
}

# Checks whether Perl JSON::PP is available for JSON edits.
# Return:
# - 0 when perl + JSON::PP are available, non-zero otherwise.
is_perl_jsonpp_available() {
  command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1
}

# Checks whether Python 3 is available for JSON edits.
# Return:
# - 0 when python3 is available, non-zero otherwise.
is_python3_available() {
  command -v python3 >/dev/null 2>&1
}

# Resolves the JSON edit engine used by this script.
# Output:
# - `perl`, `python3`, or `none`.
json_edit_engine() {
  if is_perl_jsonpp_available; then
    printf '%s\n' "perl"
  elif is_python3_available; then
    printf '%s\n' "python3"
  else
    printf '%s\n' "none"
  fi
}

is_interactive_shell() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

run_linux_perl_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y perl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y perl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y perl
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --needed --noconfirm perl
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install perl
  else
    echo "Could not detect a supported package manager for Perl installation." >&2
    return 1
  fi
}

run_macos_perl_install() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required for automatic Perl installation on macOS." >&2
    return 1
  fi
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    sudo -u "${SUDO_USER}" brew install perl
  else
    brew install perl
  fi
}

install_perl_jsonpp() {
  case "${os_name}" in
    Linux) run_linux_perl_install ;;
    Darwin) run_macos_perl_install ;;
    *) echo "Unsupported operating system for automatic Perl installation: ${os_name}" >&2; return 1 ;;
  esac

  is_perl_jsonpp_available
}

prompt_json_strategy_without_perl() {
  local answer=""

  if is_python3_available; then
    read -r -p "Perl JSON::PP is unavailable. Choose [p]ython fallback, [i]nstall Perl and continue, [r]emove whole policy files after backup, or [a]bort (default: python): " answer < /dev/tty
    answer="${answer,,}"
    case "${answer}" in
      ""|p|python|python3) printf 'python\n'; return 0 ;;
      i|install) printf 'install\n'; return 0 ;;
      r|remove) printf 'remove-files\n'; return 0 ;;
      a|abort) printf 'abort\n'; return 0 ;;
    esac
  else
    read -r -p "Perl JSON::PP and python3 are unavailable. Choose [i]nstall Perl and continue, [r]emove whole policy files after backup, or [a]bort (default: install): " answer < /dev/tty
    answer="${answer,,}"
    case "${answer}" in
      ""|i|install) printf 'install\n'; return 0 ;;
      r|remove) printf 'remove-files\n'; return 0 ;;
      a|abort) printf 'abort\n'; return 0 ;;
    esac
  fi

  echo "Invalid selection: ${answer}" >&2
  return 1
}

ensure_uninstall_json_strategy() {
  local selected_strategy=""

  is_perl_jsonpp_available && return 0
  if [[ "${yes_mode}" == true ]] || ! is_interactive_shell; then
    if is_python3_available; then
      echo "Perl JSON::PP unavailable; using python3 fallback." >&2
      return 0
    fi
    echo "A JSON edit engine is required for safe policy-key removal. Install Perl JSON::PP or python3." >&2
    return 1
  fi

  while true; do
    selected_strategy="$(prompt_json_strategy_without_perl)" || continue
    case "${selected_strategy}" in
      python) echo "Using python3 fallback for JSON policy edits."; return 0 ;;
      install) install_perl_jsonpp && return 0; echo "Perl installation failed or JSON::PP is still unavailable." >&2 ;;
      remove-files) json_fallback_mode="remove-files"; return 0 ;;
      abort) return 1 ;;
    esac
  done
}

# Validates that a policies.json file is a JSON object.
# Input:
# - $1: policies.json candidate path.
# Return:
# - 0 when valid JSON object, non-zero otherwise.
is_policy_json_valid() {
  local policy_file="$1"
  if is_perl_jsonpp_available; then
    perl -MJSON::PP -e '
use strict;
use warnings;
my ($path) = @ARGV;
open my $fh, "<", $path or exit 1;
local $/;
my $raw = <$fh>;
close $fh;
my $data = eval { JSON::PP::decode_json($raw) };
exit(($@ || ref($data) ne "HASH") ? 1 : 0);
' "${policy_file}" >/dev/null 2>&1
    return
  fi

  if is_python3_available; then
    python3 - "${policy_file}" >/dev/null 2>&1 <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(1)

raise SystemExit(0 if isinstance(data, dict) else 1)
PY
    return
  fi

  return 1
}

# Removes only Contra-managed policy keys from policies.json.
# Input:
# - $1 input policy file, $2 addon id, $3 output file.
# Output:
# - `EMPTY`, `REMOVED`, or `MISSING` status on stdout.
remove_addon_policy_entry() {
  local input_file="$1"
  local addon_id_value="$2"
  local output_file="$3"

  # Remove only Contra-managed policy keys and keep unrelated policy keys intact.
  if is_perl_jsonpp_available; then
    perl -MJSON::PP -e '
use strict;
use warnings;

my ($path, $addon_id, $output_path) = @ARGV;

open my $in_fh, "<", $path or die "Failed to read policies.json\n";
local $/;
my $raw = <$in_fh>;
close $in_fh;

my $data = eval { JSON::PP::decode_json($raw) };
if ($@) {
  die "Existing policies.json is invalid JSON.\n";
}

if (ref($data) ne "HASH") {
  die "Existing policies.json top-level must be a JSON object.\n";
}

my $removed = 0;
if (ref($data->{policies}) eq "HASH" && ref($data->{policies}->{ExtensionSettings}) eq "HASH") {
  if (exists $data->{policies}->{ExtensionSettings}->{$addon_id}) {
    delete $data->{policies}->{ExtensionSettings}->{$addon_id};
    $removed = 1;
  }

  if (ref($data->{policies}->{ExtensionSettings}) eq "HASH" && !keys %{ $data->{policies}->{ExtensionSettings} }) {
    delete $data->{policies}->{ExtensionSettings};
  }

  if (ref($data->{policies}) eq "HASH" && !keys %{ $data->{policies} }) {
    delete $data->{policies};
  }
}

if (
  ref($data->{policies}) eq "HASH" &&
  ref($data->{policies}->{"3rdparty"}) eq "HASH" &&
  ref($data->{policies}->{"3rdparty"}->{Extensions}) eq "HASH"
) {
  my $managed_entry = $data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id};
  if (ref($managed_entry) eq "HASH" && exists $managed_entry->{forceAdultBlock}) {
    delete $managed_entry->{forceAdultBlock};
    $removed = 1;
  }

  if (ref($managed_entry) eq "HASH" && !keys %{$managed_entry}) {
    delete $data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id};
  }

  if (ref($data->{policies}->{"3rdparty"}->{Extensions}) eq "HASH" && !keys %{ $data->{policies}->{"3rdparty"}->{Extensions} }) {
    delete $data->{policies}->{"3rdparty"}->{Extensions};
  }

  if (ref($data->{policies}->{"3rdparty"}) eq "HASH" && !keys %{ $data->{policies}->{"3rdparty"} }) {
    delete $data->{policies}->{"3rdparty"};
  }

  if (ref($data->{policies}) eq "HASH" && !keys %{ $data->{policies} }) {
    delete $data->{policies};
  }
}

if (ref($data->{policies}) eq "HASH" && exists $data->{policies}->{DisableSafeMode}) {
  delete $data->{policies}->{DisableSafeMode};
  $removed = 1;
}

if (ref($data->{policies}) eq "HASH" && exists $data->{policies}->{BlockAboutSupport}) {
  delete $data->{policies}->{BlockAboutSupport};
  $removed = 1;
}

if (ref($data->{policies}) eq "HASH" && exists $data->{policies}->{BlockAboutProfiles}) {
  delete $data->{policies}->{BlockAboutProfiles};
  $removed = 1;
}

if (
  ref($data->{policies}) eq "HASH" &&
  ref($data->{policies}->{Preferences}) eq "HASH" &&
  exists $data->{policies}->{Preferences}->{"extensions.installDistroAddons"}
) {
  delete $data->{policies}->{Preferences}->{"extensions.installDistroAddons"};
  $removed = 1;
  if (!keys %{ $data->{policies}->{Preferences} }) {
    delete $data->{policies}->{Preferences};
  }
}

if (ref($data->{policies}) eq "HASH" && !keys %{ $data->{policies} }) {
  delete $data->{policies};
}

if (!keys %{$data}) {
  print "EMPTY\n";
  exit 0;
}

open my $out_fh, ">", $output_path or die "Failed to write updated policies.json\n";
print {$out_fh} JSON::PP->new->utf8->canonical->pretty->encode($data);
close $out_fh or die "Failed to finalize updated policies.json\n";

if ($removed) {
  print "REMOVED\n";
} else {
  print "MISSING\n";
}
' "${input_file}" "${addon_id_value}" "${output_file}"
    return
  fi

  if ! is_python3_available; then
    echo "No supported JSON edit engine is available." >&2
    return 1
  fi

  python3 - "${input_file}" "${addon_id_value}" "${output_file}" <<'PY'
import json
import sys

path, addon_id, output_path = sys.argv[1:4]

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    raise SystemExit("Failed to read policies.json")
except json.JSONDecodeError:
    raise SystemExit("Existing policies.json is invalid JSON.")

if not isinstance(data, dict):
    raise SystemExit("Existing policies.json top-level must be a JSON object.")

removed = False
policies = data.get("policies")
if isinstance(policies, dict):
    settings = policies.get("ExtensionSettings")
    if isinstance(settings, dict):
        if addon_id in settings:
            del settings[addon_id]
            removed = True
        if not settings:
            policies.pop("ExtensionSettings", None)
        if not policies:
            data.pop("policies", None)
            policies = data.get("policies")

if isinstance(policies, dict):
    thirdparty = policies.get("3rdparty")
    extensions = thirdparty.get("Extensions") if isinstance(thirdparty, dict) else None
    managed_entry = extensions.get(addon_id) if isinstance(extensions, dict) else None
    if isinstance(managed_entry, dict) and "forceAdultBlock" in managed_entry:
        del managed_entry["forceAdultBlock"]
        removed = True
    if isinstance(managed_entry, dict) and not managed_entry and isinstance(extensions, dict):
        extensions.pop(addon_id, None)
    if isinstance(extensions, dict) and not extensions and isinstance(thirdparty, dict):
        thirdparty.pop("Extensions", None)
    if isinstance(thirdparty, dict) and not thirdparty:
        policies.pop("3rdparty", None)
    if not policies:
        data.pop("policies", None)
        policies = data.get("policies")

if isinstance(policies, dict) and "DisableSafeMode" in policies:
    del policies["DisableSafeMode"]
    removed = True

if isinstance(policies, dict) and "BlockAboutSupport" in policies:
    del policies["BlockAboutSupport"]
    removed = True

if isinstance(policies, dict) and "BlockAboutProfiles" in policies:
    del policies["BlockAboutProfiles"]
    removed = True

if isinstance(policies, dict):
    prefs = policies.get("Preferences")
    if isinstance(prefs, dict) and "extensions.installDistroAddons" in prefs:
        del prefs["extensions.installDistroAddons"]
        removed = True
        if not prefs:
            policies.pop("Preferences", None)

if isinstance(policies, dict) and not policies:
    data.pop("policies", None)

if not data:
    print("EMPTY")
    raise SystemExit(0)

with open(output_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True, ensure_ascii=False)
    fh.write("\n")

print("REMOVED" if removed else "MISSING")
PY
}

# Verifies targeted Contra policy keys are absent after removal.
# Input:
# - $1: policy file path.
# Return:
# - 0 only when targeted managed keys are absent.
verify_policy_uninstall() {
  local policy_file="$1"

  if [[ ! -f "${policy_file}" ]]; then
    echo "PASS: policies.json removed (no active enterprise policies in this file)."
    return 0
  fi

  if is_perl_jsonpp_available; then
    perl -MJSON::PP -e '
use strict;
use warnings;

my ($path, $addon_id) = @ARGV;
open my $fh, "<", $path or die "FAIL: could not read $path\n";
local $/;
my $raw = <$fh>;
close $fh;

my $data = eval { JSON::PP::decode_json($raw) };
if ($@) {
  die "FAIL: policies.json is invalid JSON\n";
}

if (ref($data) ne "HASH") {
  die "FAIL: policies.json top-level is not a JSON object\n";
}

my $settings = $data->{policies}->{ExtensionSettings};
if (ref($settings) eq "HASH" && exists $settings->{$addon_id}) {
  die "FAIL: ExtensionSettings still contains $addon_id\n";
}

my $managed = $data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id};
if (ref($managed) eq "HASH" && exists $managed->{forceAdultBlock}) {
  die "FAIL: managed policy forceAdultBlock still exists for $addon_id\n";
}

if (ref($data->{policies}) eq "HASH" && exists $data->{policies}->{DisableSafeMode}) {
  die "FAIL: DisableSafeMode still exists in policies\n";
}

if (ref($data->{policies}) eq "HASH" && exists $data->{policies}->{BlockAboutSupport}) {
  die "FAIL: BlockAboutSupport still exists in policies\n";
}

if (ref($data->{policies}) eq "HASH" && exists $data->{policies}->{BlockAboutProfiles}) {
  die "FAIL: BlockAboutProfiles still exists in policies\n";
}

if (
  ref($data->{policies}) eq "HASH" &&
  ref($data->{policies}->{Preferences}) eq "HASH" &&
  exists $data->{policies}->{Preferences}->{"extensions.installDistroAddons"}
) {
  die "FAIL: Preferences.extensions.installDistroAddons still exists in policies\n";
}

print "PASS: Contra policy entry is removed and remaining policies are valid JSON.\n";
' "${policy_file}" "${addon_id}"
    return
  fi

  if is_python3_available; then
    python3 - "${policy_file}" "${addon_id}" <<'PY'
import json
import sys

path, addon_id = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except OSError:
    raise SystemExit(f"FAIL: could not read {path}")
except json.JSONDecodeError:
    raise SystemExit("FAIL: policies.json is invalid JSON")

if not isinstance(data, dict):
    raise SystemExit("FAIL: policies.json top-level is not a JSON object")

policies = data.get("policies")
settings = policies.get("ExtensionSettings") if isinstance(policies, dict) else None
if isinstance(settings, dict) and addon_id in settings:
    raise SystemExit(f"FAIL: ExtensionSettings still contains {addon_id}")

thirdparty = policies.get("3rdparty") if isinstance(policies, dict) else None
extensions = thirdparty.get("Extensions") if isinstance(thirdparty, dict) else None
managed = extensions.get(addon_id) if isinstance(extensions, dict) else None
if isinstance(managed, dict) and "forceAdultBlock" in managed:
    raise SystemExit(f"FAIL: managed policy forceAdultBlock still exists for {addon_id}")

if isinstance(policies, dict) and "DisableSafeMode" in policies:
    raise SystemExit("FAIL: DisableSafeMode still exists in policies")

if isinstance(policies, dict) and "BlockAboutSupport" in policies:
    raise SystemExit("FAIL: BlockAboutSupport still exists in policies")

if isinstance(policies, dict) and "BlockAboutProfiles" in policies:
    raise SystemExit("FAIL: BlockAboutProfiles still exists in policies")

prefs = policies.get("Preferences") if isinstance(policies, dict) else None
if isinstance(prefs, dict) and "extensions.installDistroAddons" in prefs:
    raise SystemExit("FAIL: Preferences.extensions.installDistroAddons still exists in policies")

print("PASS: Contra policy entry is removed and remaining policies are valid JSON.")
PY
    return
  fi

  echo "FAIL: cannot validate uninstall because neither Perl JSON::PP nor python3 is available." >&2
  return 1
}

# Captures targeted policy-key state for diff-style summary.
# Input:
# - $1 policy file, $2 addon id, $3 output state file.
# Behavior:
# - Writes normalized key/value state snapshot for before/after comparison.
collect_policy_state() {
  local policy_file="$1"
  local addon_id_value="$2"
  local output_file="$3"

  if is_perl_jsonpp_available; then
    perl -MJSON::PP -e '
use strict;
use warnings;

my ($path, $addon_id) = @ARGV;
if (!-f $path) {
  print "FILE_EXISTS=0\n";
  print "POLICY_KEYS=<none>\n";
  print "HAS_DISABLE_SAFE_MODE=0\n";
  print "HAS_BLOCK_ABOUT_SUPPORT=0\n";
  print "HAS_BLOCK_ABOUT_PROFILES=0\n";
  print "HAS_DISTRO_ADDONS_PREF=0\n";
  print "HAS_EXTENSION_ENTRY=0\n";
  print "HAS_FORCE_ADULT=0\n";
  exit 0;
}

open my $fh, "<", $path or die "Could not read $path\n";
local $/;
my $raw = <$fh>;
close $fh;

my $data = eval { JSON::PP::decode_json($raw) };
if ($@) {
  die "Invalid JSON in $path\n";
}
die "Top-level JSON must be an object in $path\n" if ref($data) ne "HASH";

my $policies = $data->{policies};
my @policy_keys = ();
@policy_keys = sort keys %{$policies} if ref($policies) eq "HASH";

my $has_disable = (ref($policies) eq "HASH" && ($policies->{DisableSafeMode} // 0)) ? 1 : 0;
my $has_block_about_support = (ref($policies) eq "HASH" && ($policies->{BlockAboutSupport} // 0)) ? 1 : 0;
my $has_block_about_profiles = (ref($policies) eq "HASH" && ($policies->{BlockAboutProfiles} // 0)) ? 1 : 0;
my $prefs = (ref($policies) eq "HASH") ? $policies->{Preferences} : undef;
my $pref_entry = (ref($prefs) eq "HASH") ? $prefs->{"extensions.installDistroAddons"} : undef;
my $has_distro_pref = (
  ref($pref_entry) eq "HASH" &&
  ($pref_entry->{Value} // 0) &&
  (($pref_entry->{Status} // "") eq "locked")
) ? 1 : 0;
my $settings = (ref($policies) eq "HASH") ? $policies->{ExtensionSettings} : undef;
my $has_extension = (ref($settings) eq "HASH" && ref($settings->{$addon_id}) eq "HASH") ? 1 : 0;
my $extensions = (ref($policies) eq "HASH" && ref($policies->{"3rdparty"}) eq "HASH") ? $policies->{"3rdparty"}->{Extensions} : undef;
my $managed = (ref($extensions) eq "HASH") ? $extensions->{$addon_id} : undef;
my $has_force_adult = (ref($managed) eq "HASH" && ($managed->{forceAdultBlock} // 0)) ? 1 : 0;

print "FILE_EXISTS=1\n";
print "POLICY_KEYS=" . (@policy_keys ? join(",", @policy_keys) : "<none>") . "\n";
print "HAS_DISABLE_SAFE_MODE=$has_disable\n";
print "HAS_BLOCK_ABOUT_SUPPORT=$has_block_about_support\n";
print "HAS_BLOCK_ABOUT_PROFILES=$has_block_about_profiles\n";
print "HAS_DISTRO_ADDONS_PREF=$has_distro_pref\n";
print "HAS_EXTENSION_ENTRY=$has_extension\n";
print "HAS_FORCE_ADULT=$has_force_adult\n";
' "${policy_file}" "${addon_id_value}" > "${output_file}"
    return
  fi

  if ! is_python3_available; then
    echo "No supported JSON edit engine is available." >&2
    return 1
  fi

  python3 - "${policy_file}" "${addon_id_value}" > "${output_file}" <<'PY'
import json
import sys

path, addon_id = sys.argv[1:3]
if path and not __import__("os").path.isfile(path):
    print("FILE_EXISTS=0")
    print("POLICY_KEYS=<none>")
    print("HAS_DISABLE_SAFE_MODE=0")
    print("HAS_BLOCK_ABOUT_SUPPORT=0")
    print("HAS_BLOCK_ABOUT_PROFILES=0")
    print("HAS_DISTRO_ADDONS_PREF=0")
    print("HAS_EXTENSION_ENTRY=0")
    print("HAS_FORCE_ADULT=0")
    raise SystemExit(0)

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except OSError:
    raise SystemExit(f"Could not read {path}")
except json.JSONDecodeError:
    raise SystemExit(f"Invalid JSON in {path}")

if not isinstance(data, dict):
    raise SystemExit(f"Top-level JSON must be an object in {path}")

policies = data.get("policies")
policy_keys = sorted(policies.keys()) if isinstance(policies, dict) else []
prefs = policies.get("Preferences") if isinstance(policies, dict) else None
pref_entry = prefs.get("extensions.installDistroAddons") if isinstance(prefs, dict) else None
settings = policies.get("ExtensionSettings") if isinstance(policies, dict) else None
thirdparty = policies.get("3rdparty") if isinstance(policies, dict) else None
extensions = thirdparty.get("Extensions") if isinstance(thirdparty, dict) else None
managed = extensions.get(addon_id) if isinstance(extensions, dict) else None

has_disable = int(isinstance(policies, dict) and bool(policies.get("DisableSafeMode")))
has_block_about_support = int(isinstance(policies, dict) and bool(policies.get("BlockAboutSupport")))
has_block_about_profiles = int(isinstance(policies, dict) and bool(policies.get("BlockAboutProfiles")))
has_distro_pref = int(
    isinstance(pref_entry, dict)
    and bool(pref_entry.get("Value"))
    and pref_entry.get("Status", "") == "locked"
)
has_extension = int(isinstance(settings, dict) and isinstance(settings.get(addon_id), dict))
has_force_adult = int(isinstance(managed, dict) and bool(managed.get("forceAdultBlock")))

print("FILE_EXISTS=1")
print(f"POLICY_KEYS={','.join(policy_keys) if policy_keys else '<none>'}")
print(f"HAS_DISABLE_SAFE_MODE={has_disable}")
print(f"HAS_BLOCK_ABOUT_SUPPORT={has_block_about_support}")
print(f"HAS_BLOCK_ABOUT_PROFILES={has_block_about_profiles}")
print(f"HAS_DISTRO_ADDONS_PREF={has_distro_pref}")
print(f"HAS_EXTENSION_ENTRY={has_extension}")
print(f"HAS_FORCE_ADULT={has_force_adult}")
PY
}

# Reads a single key from captured policy-state file.
# Input:
# - $1 state file path, $2 key name.
# Output:
# - Value for key from snapshot.
state_value() {
  local state_file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1==key {print substr($0, index($0, "=") + 1); exit}' "${state_file}"
}

# Returns canonical key->label mappings for managed policy summary reporting.
# Output:
# - Lines in format `STATE_KEY|HUMAN_LABEL`.
managed_policy_state_items() {
  printf '%s\n' \
    "HAS_DISABLE_SAFE_MODE|DisableSafeMode" \
    "HAS_BLOCK_ABOUT_SUPPORT|BlockAboutSupport" \
    "HAS_BLOCK_ABOUT_PROFILES|BlockAboutProfiles" \
    "HAS_DISTRO_ADDONS_PREF|Preferences.extensions.installDistroAddons" \
    "HAS_EXTENSION_ENTRY|ExtensionSettings[${addon_id}]" \
    "HAS_FORCE_ADULT|3rdparty.Extensions[${addon_id}].forceAdultBlock"
}

# Adds labels for keys that are set to 1 in the provided state file.
# Input:
# - $1 state file, $2 destination set variable name.
add_policies_present_in_state() {
  local state_file="$1"
  local set_var_name="$2"
  local state_item=""
  local state_key=""
  local policy_label=""

  while IFS= read -r state_item; do
    state_key="${state_item%%|*}"
    policy_label="${state_item#*|}"
    if [[ "$(state_value "${state_file}" "${state_key}")" == "1" ]]; then
      add_unique_value "${set_var_name}" "${policy_label}"
    fi
  done < <(managed_policy_state_items)
}

# Adds labels for keys that moved from 1 -> 0 between before/after states.
# Input:
# - $1 before-state file, $2 after-state file.
add_removed_policies_from_state_diff() {
  local before_state_file="$1"
  local after_state_file="$2"
  local state_item=""
  local state_key=""
  local policy_label=""
  local before_value=""
  local after_value=""

  while IFS= read -r state_item; do
    state_key="${state_item%%|*}"
    policy_label="${state_item#*|}"
    before_value="$(state_value "${before_state_file}" "${state_key}")"
    after_value="$(state_value "${after_state_file}" "${state_key}")"
    if [[ "${before_value}" == "1" && "${after_value}" == "0" ]]; then
      add_unique_value policies_removed_set "${policy_label}"
    fi
  done < <(managed_policy_state_items)
}

# Checks whether all tracked managed policy keys are 0 in a state snapshot.
# Input:
# - $1 state file path.
# Return:
# - 0 when all managed keys are cleared, non-zero otherwise.
state_has_no_managed_policy_keys() {
  local state_file="$1"
  local state_item=""
  local state_key=""

  while IFS= read -r state_item; do
    state_key="${state_item%%|*}"
    if [[ "$(state_value "${state_file}" "${state_key}")" != "0" ]]; then
      return 1
    fi
  done < <(managed_policy_state_items)
  return 0
}

# Tracks whether an in-place progress bar is currently displayed.
progress_line_active=false

# Renders an in-place progress bar on a single terminal line.
# Input:
# - $1 current value, $2 total value, $3 label text.
render_progress_bar() {
  local current="$1"
  local total="$2"
  local label="$3"
  local width=30
  local filled=0
  local empty=0
  local percent=0
  local bar=""
  local i=0

  if [[ "${total}" -gt 0 ]]; then
    filled=$((current * width / total))
    percent=$((current * 100 / total))
  fi
  [[ "${filled}" -gt "${width}" ]] && filled="${width}"
  [[ "${percent}" -gt 100 ]] && percent=100
  empty=$((width - filled))
  for ((i = 0; i < filled; i += 1)); do bar+="#"; done
  for ((i = 0; i < empty; i += 1)); do bar+="-"; done
  printf '\r[%s] %3d%%  %s' "${bar}" "${percent}" "${label}"
  progress_line_active=true
}

# Finishes the in-place progress line with a trailing newline.
# Behavior:
# - Emits newline only if a progress bar line is currently active.
finish_progress_bar_line() {
  if [[ "${progress_line_active}" == true ]]; then
    printf '\n'
    progress_line_active=false
  fi
}

# Renders policy-removal progress using the fixed policy-stage percentage range.
# Input:
# - $1 current policy index, $2 total policy targets.
render_policy_removal_progress() {
  local index="$1"
  local total="$2"
  local progress_value=$((12 + (index * 58 / total)))
  render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${index}/${total})"
}

# Normalizes and adds a single unique value to a newline-separated set variable.
# Input:
# - $1 variable name, $2 value to insert when missing.
add_unique_value() {
  local var_name="$1"
  local value="$2"
  local current=""

  value="$(printf '%s' "${value}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -z "${value}" || "${value}" == "<none>" ]] && return 0
  current="${!var_name:-}"

  if printf '%s\n' "${current}" | grep -Fqx "${value}"; then
    return 0
  fi
  if [[ -z "${current}" ]]; then
    printf -v "${var_name}" '%s' "${value}"
  else
    printf -v "${var_name}" '%s\n%s' "${current}" "${value}"
  fi
}

# Converts a newline-separated unique set variable to a sorted CSV line.
# Input:
# - $1 variable name containing newline-delimited values.
# Output:
# - Sorted CSV or `none` for empty sets.
unique_values_to_csv() {
  local var_name="$1"
  local current="${!var_name:-}"
  if [[ -z "${current}" ]]; then
    printf 'none'
    return 0
  fi
  printf '%s\n' "${current}" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u | awk '
    BEGIN { first = 1 }
    {
      if (first) {
        printf "%s", $0
        first = 0
      } else {
        printf ", %s", $0
      }
    }
  '
}

# Parse CLI arguments and update runtime state.
# Unknown options fail fast to avoid silent misconfiguration.
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
    --yes|-y)
      yes_mode=true
      shift
      ;;
    --remove-profile-seed)
      remove_profile_seed=true
      shift
      ;;
    --keep-profile-seed)
      remove_profile_seed=false
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

# Validate required arguments and fail early before mutating anything.
if [[ -z "${addon_id}" ]]; then
  echo "--addon-id cannot be empty." >&2
  exit 1
fi

# Stage 1: preflight checks and privilege validation.
TOTAL_PROGRESS=100
render_progress_bar 3 "${TOTAL_PROGRESS}" "Preflight checks"
if [[ "${skip_admin_check}" != "1" && "${EUID}" -ne 0 ]]; then
  finish_progress_bar_line
  echo "Run as admin, for example: sudo bash scripts/uninstall-policy.sh" >&2
  exit 1
fi
os_name="$(uname -s)"

# Stage 2: discover policy file targets for the current host.
render_progress_bar 10 "${TOTAL_PROGRESS}" "Finding policy files"
policy_files=()
while IFS= read -r policy_candidate; do
  [[ -n "${policy_candidate}" ]] && policy_files+=("${policy_candidate}")
done < <(contra_collect_policy_files "${os_name}" "${firefox_path}" "${policy_file_override}")
if [[ ${#policy_files[@]} -eq 0 ]]; then
  finish_progress_bar_line
  echo "Could not determine any Firefox policy file targets." >&2
  exit 1
fi

# Stage 3: choose JSON edit strategy when Perl JSON::PP is unavailable.
finish_progress_bar_line
if ! ensure_uninstall_json_strategy; then
  echo "Uninstall aborted."
  exit 1
fi

# Stage 4: create temporary workspace and initialize counters/summary sets.
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
policy_index=0
failed_targets=0
updated_targets=0
removed_all_targets=0
missing_targets=0
files_changed=""
policies_removed_set=""
policies_left_set=""
other_policies_preserved=0

# Stage 5: remove managed keys from each discovered policy file target.
policy_total="${#policy_files[@]}"
render_progress_bar 12 "${TOTAL_PROGRESS}" "Removing policies (0/${policy_total})"
for policy_file in "${policy_files[@]}"; do
  # Build target-specific temp paths and per-target execution state.
  policy_index=$((policy_index + 1))
  policy_dir="$(dirname "${policy_file}")"
  before_state_file="${work_dir}/state-before-${policy_index}.txt"
  after_state_file="${work_dir}/state-after-${policy_index}.txt"
  updated_policy_json="${work_dir}/policies-updated-${policy_index}.json"
  remove_error_file="${work_dir}/remove-error-${policy_index}.log"
  target_result="unchanged"

  # Missing file is not an error; count and continue.
  if [[ ! -f "${policy_file}" ]]; then
    missing_targets=$((missing_targets + 1))
    render_policy_removal_progress "${policy_index}" "${policy_total}"
    continue
  fi

  # Existing file: back it up before any destructive operation.
  backup_dir="${policy_dir}/contra-policy-backups"
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  backup_path="${backup_dir}/policies-${timestamp}-${policy_index}.json"
  if ! install -d -m 0755 "${backup_dir}" || ! cp "${policy_file}" "${backup_path}" || ! chmod 0644 "${backup_path}"; then
    target_result="failed"
    failed_targets=$((failed_targets + 1))
    render_policy_removal_progress "${policy_index}" "${policy_total}"
    continue
  fi

  # Parser-free emergency fallback: backup was created, then remove whole file.
  if [[ "${json_fallback_mode}" == "remove-files" ]]; then
    if ! rm -f "${policy_file}"; then
      target_result="failed"
      failed_targets=$((failed_targets + 1))
      render_policy_removal_progress "${policy_index}" "${policy_total}"
      continue
    fi
    target_result="removed"
    removed_all_targets=$((removed_all_targets + 1))
    add_unique_value files_changed "${policy_file}"
    add_unique_value policies_removed_set "unknown (whole policy file removed after backup)"
    render_policy_removal_progress "${policy_index}" "${policy_total}"
    continue
  fi

  # Corrupted JSON cannot be parsed safely; remove file as fallback.
  if ! is_policy_json_valid "${policy_file}"; then
    if ! rm -f "${policy_file}"; then
      target_result="failed"
      failed_targets=$((failed_targets + 1))
      render_policy_removal_progress "${policy_index}" "${policy_total}"
      continue
    fi
    target_result="removed"
    removed_all_targets=$((removed_all_targets + 1))
    add_unique_value files_changed "${policy_file}"
    add_unique_value policies_removed_set "unknown (invalid JSON file removed)"
    render_policy_removal_progress "${policy_index}" "${policy_total}"
    continue
  fi

  # Capture before-state snapshot for accurate removal/leftover summaries.
  if ! collect_policy_state "${policy_file}" "${addon_id}" "${before_state_file}" 2>"${remove_error_file}"; then
    target_result="failed"
    failed_targets=$((failed_targets + 1))
    render_policy_removal_progress "${policy_index}" "${policy_total}"
    continue
  fi

  # Apply managed-key removal into temp output and parse status.
  if ! remove_result="$(remove_addon_policy_entry "${policy_file}" "${addon_id}" "${updated_policy_json}" 2>"${remove_error_file}")"; then
    target_result="failed"
    failed_targets=$((failed_targets + 1))
    render_policy_removal_progress "${policy_index}" "${policy_total}"
    continue
  fi
  remove_status="$(printf '%s\n' "${remove_result}" | tail -n 1 | tr -d '[:space:]')"

  # Handle each removal outcome:
  # - EMPTY   => remove policy file completely
  # - REMOVED/MISSING => write updated file
  # - other   => treat as failure
  case "${remove_status}" in
    EMPTY)
      add_policies_present_in_state "${before_state_file}" "policies_removed_set"

      if ! rm -f "${policy_file}"; then
        target_result="failed"
        failed_targets=$((failed_targets + 1))
        render_policy_removal_progress "${policy_index}" "${policy_total}"
        continue
      fi
      target_result="removed"
      removed_all_targets=$((removed_all_targets + 1))
      add_unique_value files_changed "${policy_file}"
      ;;
    REMOVED|MISSING)
      if ! install -d -m 0755 "${policy_dir}" || ! install -m 0644 "${updated_policy_json}" "${policy_file}"; then
        target_result="failed"
        failed_targets=$((failed_targets + 1))
        render_policy_removal_progress "${policy_index}" "${policy_total}"
        continue
      fi
      target_result="updated"
      updated_targets=$((updated_targets + 1))
      add_unique_value files_changed "${policy_file}"
      ;;
    *)
      target_result="failed"
      failed_targets=$((failed_targets + 1))
      render_policy_removal_progress "${policy_index}" "${policy_total}"
      continue
      ;;
  esac

  # Verify managed policy keys are absent after file mutation.
  if ! verify_policy_uninstall "${policy_file}" >/dev/null 2>&1; then
    target_result="failed"
    failed_targets=$((failed_targets + 1))
    render_policy_removal_progress "${policy_index}" "${policy_total}"
    continue
  fi

  # For updated files, compute before/after diffs for detailed summary output.
  if [[ "${target_result}" == "updated" ]]; then
    if ! collect_policy_state "${policy_file}" "${addon_id}" "${after_state_file}" 2>"${remove_error_file}"; then
      target_result="failed"
      failed_targets=$((failed_targets + 1))
      render_policy_removal_progress "${policy_index}" "${policy_total}"
      continue
    fi

    add_removed_policies_from_state_diff "${before_state_file}" "${after_state_file}"
    add_policies_present_in_state "${after_state_file}" "policies_left_set"

    if state_has_no_managed_policy_keys "${after_state_file}"; then
      other_policies_preserved=$((other_policies_preserved + 1))
    fi
  fi

  # Advance progress bar for this policy target.
  render_policy_removal_progress "${policy_index}" "${policy_total}"
done

# Stage 6: optionally remove profile-seeded XPI files from discovered profiles.
render_progress_bar 72 "${TOTAL_PROGRESS}" "Policy removal complete"
profile_removed=0
profile_missing=0
profile_failed=0
if [[ "${remove_profile_seed}" == true ]]; then
  # Gather profile list once for stable progress increments.
  profile_dirs=()
  while IFS= read -r profile_dir; do
    [[ -n "${profile_dir}" ]] && profile_dirs+=("${profile_dir}")
  done < <(contra_collect_firefox_profiles_unique)

  profile_total="${#profile_dirs[@]}"
  if [[ "${profile_total}" -gt 0 ]]; then
    profile_index=0
    render_progress_bar 73 "${TOTAL_PROGRESS}" "Cleaning profile seeds (0/${profile_total})"
    # Remove managed profile XPI and bucket outcomes for summary/failure accounting.
    for profile_dir in "${profile_dirs[@]}"; do
      profile_index=$((profile_index + 1))
      remove_result="$(contra_remove_profile_xpi "${profile_dir}" "${addon_id}")" || true
      remove_status="${remove_result%%|*}"
      case "${remove_status}" in
        removed)
          profile_removed=$((profile_removed + 1))
          add_unique_value files_changed "${remove_result##*|}"
          ;;
        missing) profile_missing=$((profile_missing + 1)) ;;
        *) profile_failed=$((profile_failed + 1)) ;;
      esac
      progress_value=$((73 + (profile_index * 15 / profile_total)))
      render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Cleaning profile seeds (${profile_index}/${profile_total})"
    done
  else
    render_progress_bar 88 "${TOTAL_PROGRESS}" "No profile seeds found"
  fi
else
  render_progress_bar 88 "${TOTAL_PROGRESS}" "Profile seed cleanup skipped"
fi

# Stage 7: finalize reporting and return script status.
render_progress_bar 100 "${TOTAL_PROGRESS}" "Complete"
finish_progress_bar_line
echo "Policies removed by this run: $(unique_values_to_csv policies_removed_set)"
echo "Policies left after this run: $(unique_values_to_csv policies_left_set)"
echo "Files changed: $(unique_values_to_csv files_changed)"

total_failures=$((failed_targets + profile_failed))
if [[ "${total_failures}" -gt 0 ]]; then
  echo "Counts: policy_files(missing=${missing_targets},updated=${updated_targets},removed=${removed_all_targets},failed=${failed_targets},other_preserved=${other_policies_preserved}); profiles(removed=${profile_removed},missing=${profile_missing},failed=${profile_failed})"
  echo "Result: failure"
  exit 1
fi
echo "Result: success"
