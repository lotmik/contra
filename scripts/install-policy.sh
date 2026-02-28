#!/usr/bin/env bash
set -euo pipefail

# Script Summary:
# - Detects Firefox policy locations (Linux/macOS), then creates backups before any write.
# - Installs strict Contra enterprise policy keys (force-install + hardening policy flags).
# - Optionally enforces managed adult mode, and can merge/overwrite/abort on conflicts.
# - Seeds Firefox profiles from AMO by default (or optional --source-xpi override).
# - Prints concise progress + final policy summary; does not install Firefox itself.
#
# Defaults:
# - Policy install URL uses the AMO latest endpoint for the published XPI.
# - Profile seed source auto-downloads from that URL unless --source-xpi is provided.
# Base constants and mutable runtime state.
# The script intentionally keeps all tunables near the top so operational behavior
# is easy to audit before execution.
DEFAULT_ADDON_ID="contra@ltdmk"
DEFAULT_INSTALL_URL="https://addons.mozilla.org/firefox/downloads/latest/contra-blocker/latest.xpi"
addon_id="${DEFAULT_ADDON_ID}"
install_url=""
source_xpi_path=""
on_conflict="merge"
on_conflict_explicit=false
yes_mode=false
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
skip_admin_check="${CONTRA_SKIP_ADMIN_CHECK:-0}"
force_adult_block=true
force_adult_block_explicit=false
profile_seed_mode="on"

# Prints CLI usage and available flags.
usage() {
  cat <<'USAGE'
Usage: scripts/install-policy.sh [options]

Install Firefox enterprise policy so Contra cannot be removed/disabled.

Options:
  --addon-id ID            Add-on ID to lock (default: contra@ltdmk)
  --source-xpi PATH        Optional local XPI path for profile seeding override
  --install-url URL        Install URL used in policy (fixed to the published AMO latest endpoint)
  --on-conflict MODE       Existing policies.json behavior: merge|overwrite|abort (default: merge)
  --firefox-path PATH      Optional Firefox app/bin/install path to include (default: auto-detect)
  --adult                  Force-enable adult blocking via enterprise policy (hides toggle in UI)
  --no-adult               Do not set force adult policy flag
  --profile-seed MODE      Profile seeding mode: on|off (default: on)
  --yes, -y                Non-interactive mode (use selected/default options)
  -h, --help               Show help
USAGE
}

# Prompts with a default-yes confirmation in interactive mode.
# Input:
# - $1: prompt text displayed to the operator.
# Behavior:
# - Empty input is treated as "yes" to keep the install flow quick.
# - Returns 0 for yes and 1 for no.
ask_yes_no_default_yes() {
  local prompt="$1"
  local answer=""
  while true; do
    read -r -p "${prompt} [Y/n]: " answer
    answer="${answer,,}"
    case "${answer}" in
      ""|y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        echo "Please answer y or n."
        ;;
    esac
  done
}

# Resolves profile-seed XPI path, downloading from install URL when needed.
# Input:
# - $1: temporary download destination used when source XPI is not explicitly set.
# Behavior:
# - Honors `profile_seed_mode`; if seeding is disabled, no work is done.
# - Validates explicit local source if provided.
# - Otherwise downloads from install URL and points `source_xpi_path` at downloaded file.
resolve_source_xpi_for_seeding() {
  local download_target="$1"
  local fetch_log="${download_target}.fetch.log"

  if [[ "${profile_seed_mode}" != "on" ]]; then
    return 0
  fi

  if [[ -n "${source_xpi_path}" ]]; then
    if [[ ! -f "${source_xpi_path}" || ! -r "${source_xpi_path}" ]]; then
      echo "Source XPI is missing or unreadable: ${source_xpi_path}" >&2
      return 1
    fi
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 "${install_url}" -o "${download_target}" 2>"${fetch_log}"; then
      echo "Could not download XPI from install URL for profile seeding." >&2
      rm -f "${fetch_log}" >/dev/null 2>&1 || true
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "${download_target}" "${install_url}" 2>"${fetch_log}"; then
      echo "Could not download XPI from install URL for profile seeding." >&2
      rm -f "${fetch_log}" >/dev/null 2>&1 || true
      return 1
    fi
  else
    echo "Profile seeding requires curl or wget when --source-xpi is not provided." >&2
    return 1
  fi

  if [[ ! -s "${download_target}" ]]; then
    echo "Downloaded XPI is empty; profile seeding cannot continue." >&2
    rm -f "${fetch_log}" >/dev/null 2>&1 || true
    return 1
  fi

  rm -f "${fetch_log}" >/dev/null 2>&1 || true
  source_xpi_path="${download_target}"
  return 0
}

# Escapes shell strings for safe JSON interpolation.
# Input:
# - $1: raw string to escape for JSON string literals.
# Output:
# - Escaped value written to stdout.
json_escape() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//$'\n'/\\n}"
  raw="${raw//$'\r'/\\r}"
  raw="${raw//$'\t'/\\t}"
  printf '%s' "${raw}"
}

# Checks whether Perl JSON::PP is available for JSON edits.
# Return:
# - 0 when perl + JSON::PP are available, non-zero otherwise.
is_perl_jsonpp_available() {
  command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1
}

# Validates that a policies.json file is a JSON object.
# Input:
# - $1: path to candidate policies.json file.
# Return:
# - 0 when valid JSON object, non-zero otherwise.
is_policy_json_valid() {
  local policy_file="$1"
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
}

# Asks user how to handle an existing policies.json file.
# Return:
# - Selected mode printed to stdout: merge / overwrite / abort.
choose_conflict_mode_interactive() {
  local selected=""
  while true; do
    read -r -p "Existing policies.json found. Choose [m]erge, [o]verwrite, or [a]bort (default: merge): " selected
    selected="${selected,,}"
    case "${selected}" in
      ""|m|merge)
        printf 'merge'
        return 0
        ;;
      o|overwrite)
        printf 'overwrite'
        return 0
        ;;
      a|abort)
        printf 'abort'
        return 0
        ;;
      *)
        echo "Invalid selection: ${selected}" >&2
        ;;
    esac
  done
}

# Asks for overwrite or abort when merge support is unavailable.
# Return:
# - Selected mode printed to stdout: overwrite / abort.
choose_conflict_mode_without_merge() {
  local selected=""
  while true; do
    read -r -p "Merge engine unavailable. Choose [o]verwrite or [a]bort: " selected
    selected="${selected,,}"
    case "${selected}" in
      o|overwrite)
        printf 'overwrite'
        return 0
        ;;
      a|abort)
        printf 'abort'
        return 0
        ;;
      *)
        echo "Invalid selection: ${selected}" >&2
        ;;
    esac
  done
}

# Emits common Linux Firefox policies.json targets.
# Output:
# - One candidate path per line.
# Notes:
# - Includes both well-known static paths and discovered wildcard roots.
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
    if [[ -d "${base}" ]]; then
      printf '%s\n' "${base}/policies/policies.json"
    fi
  done

  for base in /usr/lib/firefox* /usr/lib64/firefox* /usr/local/lib/firefox* /usr/local/firefox* /opt/firefox*; do
    if [[ -d "${base}" ]]; then
      printf '%s\n' "${base}/distribution/policies.json"
    fi
  done
}

# Emits common macOS Firefox app bundle paths.
# Output:
# - Candidate `.app` directories, one per line.
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
# - $1: user-provided Firefox binary/install/policy path.
# Output:
# - Normalized policies.json path on success.
contra_normalize_linux_policy_file() {
  local input_path="$1"

  case "${input_path}" in
    */policies.json)
      printf '%s\n' "${input_path}"
      return 0
      ;;
    */distribution)
      printf '%s/policies.json\n' "${input_path}"
      return 0
      ;;
    */policies)
      printf '%s/policies.json\n' "${input_path}"
      return 0
      ;;
    */firefox|*/firefox-bin|*/firefox-esr)
      printf '%s/distribution/policies.json\n' "$(dirname "${input_path}")"
      return 0
      ;;
  esac

  if [[ -d "${input_path}" ]]; then
    if [[ -d "${input_path}/distribution" ]]; then
      printf '%s/distribution/policies.json\n' "${input_path}"
      return 0
    fi
    if [[ -d "${input_path}/policies" ]]; then
      printf '%s/policies/policies.json\n' "${input_path}"
      return 0
    fi
  fi

  return 1
}

# Normalizes macOS inputs into a policies.json file path.
# Input:
# - $1: user-provided Firefox `.app` or nested bundle path.
# Output:
# - Normalized policies.json path on success.
contra_normalize_macos_policy_file() {
  local input_path="$1"
  local app_path=""

  case "${input_path}" in
    *.app)
      app_path="${input_path}"
      ;;
    */Contents/MacOS/firefox)
      app_path="${input_path%/Contents/MacOS/firefox}"
      ;;
    */Contents/Resources/distribution)
      app_path="${input_path%/Contents/Resources/distribution}"
      ;;
    */Contents/Resources/distribution/policies.json)
      app_path="${input_path%/Contents/Resources/distribution/policies.json}"
      ;;
    *)
      if [[ -d "${input_path}/Contents/Resources" ]]; then
        app_path="${input_path}"
      fi
      ;;
  esac

  if [[ -n "${app_path}" ]]; then
    printf '%s/Contents/Resources/distribution/policies.json\n' "${app_path}"
    return 0
  fi

  return 1
}

# Collects unique policy-file targets for the current OS.
# Input:
# - $1: OS name (`uname -s`).
# - $2: optional Firefox path override.
# - $3: optional explicit policy file override.
# Output:
# - Deduplicated candidate policy paths, one per line.
contra_collect_policy_files() {
  local os_name="$1"
  local firefox_path_override="${2:-}"
  local policy_file_override_local="${3:-}"
  local normalized_path=""
  local -a candidates=()
  local candidate
  local install_root=""

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

    if [[ ${#candidates[@]} -eq 0 ]]; then
      echo "Could not locate Firefox app bundle(s)." >&2
      echo "Pass --firefox-path '/Applications/Firefox.app' (or your custom Firefox .app path)." >&2
      return 1
    fi

    printf '%s\n' "${candidates[@]}" | awk 'NF && !seen[$0]++'
    return 0
  fi

  echo "Unsupported operating system: ${os_name}" >&2
  return 1
}

# Scans home directories for Firefox profile roots.
# Output:
# - Existing profile-root directories from common home locations.
contra_emit_profile_roots_from_homes() {
  local home_dir
  for home_dir in /home/* /root; do
    if [[ -d "${home_dir}/.mozilla/firefox" ]]; then
      printf '%s\n' "${home_dir}/.mozilla/firefox"
    fi
  done
}

# Builds candidate Firefox profile roots in priority order.
# Output:
# - Candidate roots in preferred lookup order.
# Notes:
# - Honors `CONTRA_FIREFOX_PROFILE_ROOTS` first, then sudo/current/home scans.
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
# - Deduplicated roots that currently exist.
contra_collect_profile_roots() {
  contra_emit_profile_roots | awk 'NF && !seen[$0]++ && system("[ -d \"" $0 "\" ]") == 0'
}

# Reads profiles.ini and emits resolved profile paths.
# Input:
# - $1: profile root directory containing profiles.ini.
# Output:
# - Resolved profile directories, one per line.
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
# - $1: profile root directory.
# Output:
# - Candidate profile directories that look like real profiles.
contra_emit_profiles_from_root_scan() {
  local profile_root="$1"
  local profile_dir=""
  local base_name=""

  for profile_dir in "${profile_root}"/*; do
    [[ ! -d "${profile_dir}" ]] && continue
    base_name="$(basename "${profile_dir}")"
    case "${base_name}" in
      "Crash Reports"|"Pending Pings"|"Profile Groups")
        continue
        ;;
    esac
    if [[ -f "${profile_dir}/prefs.js" || -f "${profile_dir}/times.json" || -f "${profile_dir}/extensions.json" ]]; then
      printf '%s\n' "${profile_dir}"
    fi
  done
}

# Collects profile directories from all discovered roots.
# Output:
# - Potential Firefox profile directories discovered from all roots.
contra_collect_firefox_profiles() {
  local profile_root=""
  while IFS= read -r profile_root; do
    [[ -z "${profile_root}" || ! -d "${profile_root}" ]] && continue
    contra_emit_profiles_from_profiles_ini "${profile_root}"
    contra_emit_profiles_from_root_scan "${profile_root}"
  done < <(contra_collect_profile_roots)
}

# Returns unique existing Firefox profile directories.
# Output:
# - Deduplicated profile directories that exist at execution time.
contra_collect_firefox_profiles_unique() {
  contra_collect_firefox_profiles | awk 'NF && !seen[$0]++ && system("[ -d \"" $0 "\" ]") == 0'
}

# Builds managed extension XPI path for a profile.
# Input:
# - $1: profile directory.
# - $2: addon id.
# Output:
# - Full path to profile-managed XPI file.
contra_profile_extension_path() {
  local profile_dir="$1"
  local addon_id_local="$2"
  printf '%s/extensions/%s.xpi' "${profile_dir}" "${addon_id_local}"
}

# Returns numeric owner:group for ownership-preserving writes.
# Input:
# - $1: filesystem path whose ownership should be mirrored.
# Output:
# - `uid:gid` on stdout when available.
contra_owner_group_for_path() {
  local target_path="$1"
  stat -c '%u:%g' "${target_path}" 2>/dev/null || true
}

# Seeds or updates managed XPI in one Firefox profile.
# Input:
# - $1: profile dir, $2: source xpi, $3: addon id.
# Output:
# - status tuple: `status|profile_dir|target_file`.
# Notes:
# - Preserves profile ownership for created/updated files when possible.
contra_seed_profile_xpi() {
  local profile_dir="$1"
  local source_xpi="$2"
  local addon_id_local="$3"
  local extension_dir="${profile_dir}/extensions"
  local extension_file=""
  local owner_group=""
  local action="seeded"
  local had_existing=false

  extension_file="$(contra_profile_extension_path "${profile_dir}" "${addon_id_local}")"

  [[ ! -d "${profile_dir}" ]] && { printf 'failed|%s|profile directory missing\n' "${profile_dir}"; return 1; }
  [[ ! -f "${source_xpi}" ]] && { printf 'failed|%s|source XPI missing: %s\n' "${profile_dir}" "${source_xpi}"; return 1; }

  owner_group="$(contra_owner_group_for_path "${profile_dir}")"

  if [[ -f "${extension_file}" ]]; then
    had_existing=true
    if cmp -s "${source_xpi}" "${extension_file}"; then
      printf 'already up-to-date|%s|%s\n' "${profile_dir}" "${extension_file}"
      return 0
    fi
    action="updated"
  fi

  install -d -m 0755 "${extension_dir}" || { printf 'failed|%s|could not create extensions directory: %s\n' "${profile_dir}" "${extension_dir}"; return 1; }
  [[ -n "${owner_group}" ]] && chown "${owner_group}" "${extension_dir}" >/dev/null 2>&1 || true

  install -m 0644 "${source_xpi}" "${extension_file}" || { printf 'failed|%s|could not write extension file: %s\n' "${profile_dir}" "${extension_file}"; return 1; }
  [[ -n "${owner_group}" ]] && chown "${owner_group}" "${extension_file}" >/dev/null 2>&1 || true

  [[ "${had_existing}" == false ]] && action="seeded"
  printf '%s|%s|%s\n' "${action}" "${profile_dir}" "${extension_file}"
}

# Renders desired strict Contra enterprise policy JSON.
# Input:
# - $1: destination JSON path.
# Behavior:
# - Writes full managed policy object; includes 3rdparty block only when
#   force-adult mode is enabled.
render_target_policy_json() {
  local output_file="$1"
  local addon_id_escaped install_url_escaped
  addon_id_escaped="$(json_escape "${addon_id}")"
  install_url_escaped="$(json_escape "${install_url}")"

  if [[ "${force_adult_block}" == true ]]; then
    cat > "${output_file}" <<EOF_JSON
{
  "policies": {
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
    },
    "3rdparty": {
      "Extensions": {
        "${addon_id_escaped}": {
          "forceAdultBlock": true
        }
      }
    }
  }
}
EOF_JSON
    return 0
  fi

  cat > "${output_file}" <<EOF_JSON
{
  "policies": {
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
  }
}
EOF_JSON
}

# Merges Contra policy keys into existing policies.json.
# Input:
# - $1: existing policy file, $2: merged output file, $3: force-adult flag,
#   $4: force-adult-explicit flag.
# Behavior:
# - Preserves unrelated existing keys while enforcing Contra-managed keys.
merge_policy_json_with_existing() {
  local existing_policy_file="$1"
  local merged_output_file="$2"
  local force_adult_flag="$3"
  local force_adult_explicit_flag="$4"

  perl -MJSON::PP -e '
use strict;
use warnings;

my ($existing_path, $addon_id, $install_url, $force_adult_flag, $force_adult_explicit_flag, $output_path) = @ARGV;

open my $existing_fh, "<", $existing_path or die "Failed to read existing policy: $existing_path\n";
local $/;
my $raw = <$existing_fh>;
close $existing_fh;

my $data = {};
if (defined $raw && $raw =~ /\S/) {
  eval { $data = JSON::PP::decode_json($raw); 1 }
    or die "Existing policies.json is invalid JSON.\n";
}

if (ref($data) ne "HASH") {
  die "Existing policies.json top-level must be a JSON object.\n";
}

$data->{policies} = {} if !exists $data->{policies} || ref($data->{policies}) ne "HASH";
$data->{policies}->{DisableSafeMode} = JSON::PP::true;
$data->{policies}->{BlockAboutSupport} = JSON::PP::true;
$data->{policies}->{BlockAboutProfiles} = JSON::PP::true;
$data->{policies}->{ExtensionSettings} = {}
  if !exists $data->{policies}->{ExtensionSettings} || ref($data->{policies}->{ExtensionSettings}) ne "HASH";

$data->{policies}->{Preferences} = {}
  if !exists $data->{policies}->{Preferences} || ref($data->{policies}->{Preferences}) ne "HASH";
$data->{policies}->{Preferences}->{"extensions.installDistroAddons"} = {
  Value => JSON::PP::true,
  Status => "locked",
};

$data->{policies}->{ExtensionSettings}->{$addon_id} = {
  installation_mode => "force_installed",
  install_url => $install_url,
  private_browsing => JSON::PP::true,
};

if ($force_adult_flag eq "true") {
  $data->{policies}->{"3rdparty"} = {}
    if !exists $data->{policies}->{"3rdparty"} || ref($data->{policies}->{"3rdparty"}) ne "HASH";
  $data->{policies}->{"3rdparty"}->{Extensions} = {}
    if !exists $data->{policies}->{"3rdparty"}->{Extensions} || ref($data->{policies}->{"3rdparty"}->{Extensions}) ne "HASH";

  my $extension_data = $data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id};
  $extension_data = {} if ref($extension_data) ne "HASH";
  $extension_data->{forceAdultBlock} = JSON::PP::true;
  $data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id} = $extension_data;
} elsif ($force_adult_explicit_flag eq "true") {
  if (
    ref($data->{policies}->{"3rdparty"}) eq "HASH" &&
    ref($data->{policies}->{"3rdparty"}->{Extensions}) eq "HASH" &&
    ref($data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id}) eq "HASH"
  ) {
    delete $data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id}->{forceAdultBlock};
    if (!keys %{ $data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id} }) {
      delete $data->{policies}->{"3rdparty"}->{Extensions}->{$addon_id};
    }
    if (!keys %{ $data->{policies}->{"3rdparty"}->{Extensions} }) {
      delete $data->{policies}->{"3rdparty"}->{Extensions};
    }
    if (!keys %{ $data->{policies}->{"3rdparty"} }) {
      delete $data->{policies}->{"3rdparty"};
    }
  }
}

open my $out_fh, ">", $output_path or die "Failed to write merged policy output.\n";
print {$out_fh} JSON::PP->new->utf8->canonical->pretty->encode($data);
close $out_fh or die "Failed to finalize merged policy output.\n";
' "${existing_policy_file}" "${addon_id}" "${install_url}" "${force_adult_flag}" "${force_adult_explicit_flag}" "${merged_output_file}"
}

# Verifies required policy keys after write operation.
# Input:
# - $1: policy file path, $2: whether force-adult key must exist.
# Return:
# - 0 only when resulting policies meet strict expected contract.
verify_policy_install() {
  local policy_file="$1"
  local expect_force_adult_flag="$2"

  if [[ ! -f "${policy_file}" ]]; then
    return 1
  fi

  if ! is_perl_jsonpp_available; then
    echo "Perl JSON::PP is required to verify policy install." >&2
    return 1
  fi

  perl -MJSON::PP -e '
use strict;
use warnings;
my ($path, $addon_id, $install_url, $expect_force_adult_flag) = @ARGV;
open my $fh, "<", $path or die;
local $/;
my $raw = <$fh>;
close $fh;
my $data = eval { JSON::PP::decode_json($raw) }; die if $@;
die if ref($data) ne "HASH";
my $policies = $data->{policies};
die if ref($policies) ne "HASH";
die if !($policies->{DisableSafeMode} // 0);
die if !($policies->{BlockAboutSupport} // 0);
die if !($policies->{BlockAboutProfiles} // 0);

my $prefs = $policies->{Preferences};
die if ref($prefs) ne "HASH";
my $pref = $prefs->{"extensions.installDistroAddons"};
die if ref($pref) ne "HASH";
die if !($pref->{Value} // 0);
die if (($pref->{Status} // "") ne "locked");

my $settings = $policies->{ExtensionSettings};
die if ref($settings) ne "HASH";
my $entry = $settings->{$addon_id};
die if ref($entry) ne "HASH";
die if (($entry->{installation_mode} // "") ne "force_installed");
die if (($entry->{install_url} // "") ne $install_url);
die if !($entry->{private_browsing} // 0);

if ($expect_force_adult_flag eq "true") {
  my $managed = $policies->{"3rdparty"}->{Extensions}->{$addon_id};
  die if ref($managed) ne "HASH";
  die if !($managed->{forceAdultBlock} // 0);
}
' "${policy_file}" "${addon_id}" "${install_url}" "${expect_force_adult_flag}" >/dev/null 2>&1
}

# Validates and normalizes profile-seed mode option.
# Input:
# - $1: raw mode value.
# Output:
# - Normalized mode (`on`/`off`) to stdout.
normalize_profile_seed_mode() {
  local raw_mode="${1,,}"
  case "${raw_mode}" in
    on|off)
      printf '%s' "${raw_mode}"
      ;;
    *)
      return 1
      ;;
  esac
}

# Tracks whether an in-place progress bar is currently displayed.
progress_line_active=false

# Renders an in-place progress bar on a single terminal line.
# Input:
# - $1 current progress value, $2 total, $3 label text.
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
# - Adds a newline only when a progress line is currently active.
finish_progress_bar_line() {
  if [[ "${progress_line_active}" == true ]]; then
    printf '\n'
    progress_line_active=false
  fi
}

# Renders policy-apply progress with the script's fixed percentage window.
# Input:
# - $1 current policy index, $2 total policies.
render_policy_apply_progress() {
  local index="$1"
  local total="$2"
  local progress_value=$((12 + (index * 53 / total)))
  render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Applying policies (${index}/${total})"
}

# Normalizes and adds a single unique value to a newline-separated set variable.
# Input:
# - $1: variable name containing newline-delimited values.
# - $2: value to normalize and insert when missing.
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
# - $1: variable name containing newline-delimited set values.
# Output:
# - Sorted CSV (or `none` when empty).
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
# This section intentionally validates known flags and rejects unknown input.
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
    --source-xpi)
      source_xpi_path="${2:-}"
      [[ -n "${source_xpi_path}" ]] || { echo "--source-xpi cannot be empty when provided." >&2; exit 1; }
      shift 2
      ;;
    --source-xpi=*)
      source_xpi_path="${1#*=}"
      [[ -n "${source_xpi_path}" ]] || { echo "--source-xpi cannot be empty when provided." >&2; exit 1; }
      shift
      ;;
    --install-url)
      install_url="${2:-}"
      shift 2
      ;;
    --install-url=*)
      install_url="${1#*=}"
      shift
      ;;
    --on-conflict)
      on_conflict="${2:-}"
      on_conflict_explicit=true
      shift 2
      ;;
    --on-conflict=*)
      on_conflict="${1#*=}"
      on_conflict_explicit=true
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
    --adult)
      force_adult_block=true
      force_adult_block_explicit=true
      shift
      ;;
    --no-adult)
      force_adult_block=false
      force_adult_block_explicit=true
      shift
      ;;
    --profile-seed)
      profile_seed_mode="${2:-}"
      shift 2
      ;;
    --profile-seed=*)
      profile_seed_mode="${1#*=}"
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

# Validate required arguments and normalize simple mode fields.
[[ -z "${addon_id}" ]] && { echo "--addon-id cannot be empty." >&2; exit 1; }

if ! profile_seed_mode="$(normalize_profile_seed_mode "${profile_seed_mode}")"; then
  echo "Invalid --profile-seed value: ${profile_seed_mode}. Use on|off." >&2
  exit 1
fi

# Normalize conflict mode and reject unsupported values early.
on_conflict="${on_conflict,,}"
case "${on_conflict}" in
  merge|overwrite|abort) ;;
  *)
    echo "Invalid --on-conflict value: ${on_conflict}. Use merge|overwrite|abort." >&2
    exit 1
    ;;
esac

# Enforce fixed install URL policy for safe, predictable deployments.
if [[ -z "${install_url}" ]]; then
  install_url="${DEFAULT_INSTALL_URL}"
fi
if [[ "${install_url}" != "${DEFAULT_INSTALL_URL}" ]]; then
  echo "--install-url is fixed to the published AMO latest URL: ${DEFAULT_INSTALL_URL}" >&2
  exit 1
fi

# Optional interactive confirmation for force-adult mode in operator-driven runs.
if [[ "${force_adult_block_explicit}" == false && "${yes_mode}" == false ]]; then
  if ask_yes_no_default_yes "Enable forced adult blocking (closes every adult website before it loads)"; then
    force_adult_block=true
  else
    force_adult_block=false
  fi
fi

# Stage 1: preflight checks (privilege + environment sanity).
TOTAL_PROGRESS=100
render_progress_bar 3 "${TOTAL_PROGRESS}" "Preflight checks"
if [[ "${skip_admin_check}" != "1" && "${EUID}" -ne 0 ]]; then
  finish_progress_bar_line
  echo "Run as admin, for example: sudo bash scripts/install-policy.sh"
  exit 1
fi

# Stage 2: decide operating mode for merge fallback when JSON merge engine is unavailable.
os_name="$(uname -s)"
if [[ "${on_conflict}" == "merge" ]] && ! is_perl_jsonpp_available; then
  if [[ "${yes_mode}" == true ]]; then
    finish_progress_bar_line
    echo "Merge mode requires Perl JSON::PP, or use --on-conflict overwrite."
    exit 1
  fi
  on_conflict="$(choose_conflict_mode_without_merge)"
fi
effective_conflict_mode="${on_conflict}"

# Stage 3: discover target policy files.
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

# Stage 4: create temporary workspace and cleanup trap.
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

# Stage 5: resolve profile seed source only when seeding is enabled.
if [[ "${profile_seed_mode}" == "on" ]]; then
  render_progress_bar 11 "${TOTAL_PROGRESS}" "Preparing profile seed source"
  if ! resolve_source_xpi_for_seeding "${work_dir}/contra-seed-source.xpi"; then
    finish_progress_bar_line
    exit 1
  fi
fi

# Stage 6: render desired managed policy payload once and reuse for all targets.
target_policy_json="${work_dir}/contra-policy-target.json"
render_target_policy_json "${target_policy_json}"

# Stage 7: initialize counters and summary sets for final report output.
prompted_conflict_choice=false
policy_index=0
failed_targets=0
updated_targets=0
created_targets=0
files_changed=""
added_policies_set=""
left_policies_set=""
install_policy_summary_items=(
  "DisableSafeMode"
  "BlockAboutSupport"
  "BlockAboutProfiles"
  "Preferences.extensions.installDistroAddons"
  "ExtensionSettings[${addon_id}]"
)
if [[ "${force_adult_block}" == true ]]; then
  install_policy_summary_items+=("3rdparty.Extensions[${addon_id}].forceAdultBlock")
fi
# Pre-fill summary sets with the policy keys this run is designed to enforce.
for policy_item in "${install_policy_summary_items[@]}"; do
  add_unique_value added_policies_set "${policy_item}"
  add_unique_value left_policies_set "${policy_item}"
done

# Stage 8: apply policy updates across all discovered targets.
policy_total="${#policy_files[@]}"
render_progress_bar 12 "${TOTAL_PROGRESS}" "Applying policies (0/${policy_total})"
for policy_file in "${policy_files[@]}"; do
  # Build per-target temporary filenames and execution context.
  policy_index=$((policy_index + 1))
  policy_dir="$(dirname "${policy_file}")"
  final_policy_json="${work_dir}/contra-policy-final-${policy_index}.json"
  file_existed=false

  # Existing policy file path: backup first, then merge/overwrite behavior.
  if [[ -f "${policy_file}" ]]; then
    # Always create a timestamped backup before mutating an existing file.
    file_existed=true
    backup_dir="${policy_dir}/contra-policy-backups"
    timestamp="$(date -u +%Y%m%d%H%M%S)"
    backup_path="${backup_dir}/policies-${timestamp}-${policy_index}.json"
    if ! install -d -m 0755 "${backup_dir}" || ! cp "${policy_file}" "${backup_path}" || ! chmod 0644 "${backup_path}"; then
      failed_targets=$((failed_targets + 1))
      render_policy_apply_progress "${policy_index}" "${policy_total}"
      continue
    fi

    # Invalid JSON cannot be merged safely; reset target using strict template.
    if ! is_policy_json_valid "${policy_file}"; then
      if ! rm -f "${policy_file}"; then
        failed_targets=$((failed_targets + 1))
        render_policy_apply_progress "${policy_index}" "${policy_total}"
        continue
      fi
      cp "${target_policy_json}" "${final_policy_json}"
      file_existed=false
    else
      # Interactive conflict prompt is shown once unless explicitly configured.
      if [[ "${on_conflict_explicit}" == false && "${yes_mode}" == false && "${prompted_conflict_choice}" == false ]]; then
        effective_conflict_mode="$(choose_conflict_mode_interactive)"
        prompted_conflict_choice=true
      fi
      # Apply selected conflict policy: abort, overwrite, or merge-with-fallback.
      case "${effective_conflict_mode}" in
        abort)
          finish_progress_bar_line
          echo "Install aborted."
          exit 0
          ;;
        overwrite)
          cp "${target_policy_json}" "${final_policy_json}"
          ;;
        merge)
          if merge_policy_json_with_existing "${policy_file}" "${final_policy_json}" "${force_adult_block}" "${force_adult_block_explicit}" >/dev/null 2>&1; then
            :
          else
            cp "${target_policy_json}" "${final_policy_json}"
          fi
          ;;
      esac
    fi
  # New file path: write strict template directly.
  else
    cp "${target_policy_json}" "${final_policy_json}"
  fi

  # Persist final JSON and verify managed policy contract after write.
  if ! install -d -m 0755 "${policy_dir}" || ! install -m 0644 "${final_policy_json}" "${policy_file}" || ! verify_policy_install "${policy_file}" "${force_adult_block}" >/dev/null 2>&1; then
    failed_targets=$((failed_targets + 1))
  else
    add_unique_value files_changed "${policy_file}"
    if [[ "${file_existed}" == true ]]; then
      updated_targets=$((updated_targets + 1))
    else
      created_targets=$((created_targets + 1))
    fi
  fi

  # Move progress bar through the policy-application range.
  render_policy_apply_progress "${policy_index}" "${policy_total}"
done

# Stage 9: optionally seed profile XPI files to pre-populate existing profiles.
render_progress_bar 65 "${TOTAL_PROGRESS}" "Policy update complete"
profile_seeded=0
profile_updated=0
profile_up_to_date=0
profile_failed=0
if [[ "${profile_seed_mode}" == "on" ]]; then
  # Gather profile directories once to compute deterministic progress increments.
  profile_dirs=()
  while IFS= read -r profile_dir; do
    [[ -n "${profile_dir}" ]] && profile_dirs+=("${profile_dir}")
  done < <(contra_collect_firefox_profiles_unique)

  profile_total="${#profile_dirs[@]}"
  if [[ "${profile_total}" -gt 0 ]]; then
    profile_index=0
    render_progress_bar 66 "${TOTAL_PROGRESS}" "Seeding profiles (0/${profile_total})"
    # Seed each profile and bucket results for summary/failure accounting.
    for profile_dir in "${profile_dirs[@]}"; do
      profile_index=$((profile_index + 1))
      seed_result="$(contra_seed_profile_xpi "${profile_dir}" "${source_xpi_path}" "${addon_id}")" || true
      seed_status="${seed_result%%|*}"
      case "${seed_status}" in
        seeded) profile_seeded=$((profile_seeded + 1)) ;;
        updated) profile_updated=$((profile_updated + 1)) ;;
        "already up-to-date") profile_up_to_date=$((profile_up_to_date + 1)) ;;
        *) profile_failed=$((profile_failed + 1)) ;;
      esac
      progress_value=$((66 + (profile_index * 19 / profile_total)))
      render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Seeding profiles (${profile_index}/${profile_total})"
    done
  else
    render_progress_bar 85 "${TOTAL_PROGRESS}" "No profiles found to seed"
  fi
else
  render_progress_bar 85 "${TOTAL_PROGRESS}" "Profile seeding skipped"
fi

# Stage 10: print final summaries and return success/failure status.
render_progress_bar 100 "${TOTAL_PROGRESS}" "Complete"
finish_progress_bar_line
echo "Policies added by this run: $(unique_values_to_csv added_policies_set)"
echo "Policies removed by this run: none"
echo "Policies left after this run: $(unique_values_to_csv left_policies_set)"
echo "Files changed: $(unique_values_to_csv files_changed)"

total_failures=$((failed_targets + profile_failed))
if [[ "${total_failures}" -gt 0 ]]; then
  echo "Counts: policy_files(created=${created_targets},updated=${updated_targets},failed=${failed_targets}); profiles(seeded=${profile_seeded},updated=${profile_updated},up_to_date=${profile_up_to_date},failed=${profile_failed})"
  echo "Result: failure"
  exit 1
fi
echo "Result: success"
