#!/usr/bin/env bash
set -euo pipefail

# Script Summary:
# - Detects Firefox policy locations (Linux/macOS), then creates backups before edits.
# - Removes only Contra-managed enterprise policy keys while preserving unrelated keys.
# - Optionally removes profile-seeded XPI files and legacy runtime guard artifacts.
# - Prints concise progress + final deduplicated policy summary.
DEFAULT_ADDON_ID="contra@ltdmk"
addon_id="${DEFAULT_ADDON_ID}"
yes_mode=false
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
skip_admin_check="${CONTRA_SKIP_ADMIN_CHECK:-0}"
remove_guard=true
remove_profile_seed=true

# Prints CLI usage and available flags.
usage() {
  cat <<'USAGE'
Usage: scripts/uninstall-policy.sh [options]

Remove Contra Firefox enterprise policy lock while preserving unrelated policies.

Options:
  --addon-id ID            Add-on ID to unlock (default: contra@ltdmk)
  --firefox-path PATH      Optional Firefox app/bin/install path to include (default: auto-detect)
  --remove-guard           Remove legacy runtime guard artifacts (default: true)
  --keep-guard             Skip runtime guard artifact cleanup
  --remove-profile-seed    Remove profile-seeded extension files (default: true)
  --keep-profile-seed      Keep profile-seeded extension files
  --yes, -y                Non-interactive mode (currently informational)
  -h, --help               Show help
USAGE
}

# Emits common Linux Firefox policies.json targets.
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
contra_emit_profile_roots_from_homes() {
  local home_dir
  for home_dir in /home/* /root; do
    [[ -d "${home_dir}/.mozilla/firefox" ]] && printf '%s\n' "${home_dir}/.mozilla/firefox"
  done
}

# Builds candidate Firefox profile roots in priority order.
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
contra_collect_profile_roots() {
  contra_emit_profile_roots | awk 'NF && !seen[$0]++ && system("[ -d \"" $0 "\" ]") == 0'
}

# Reads profiles.ini and emits resolved profile paths.
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
contra_collect_firefox_profiles() {
  local profile_root
  while IFS= read -r profile_root; do
    [[ -z "${profile_root}" || ! -d "${profile_root}" ]] && continue
    contra_emit_profiles_from_profiles_ini "${profile_root}"
    contra_emit_profiles_from_root_scan "${profile_root}"
  done < <(contra_collect_profile_roots)
}

# Returns unique existing Firefox profile directories.
contra_collect_firefox_profiles_unique() {
  contra_collect_firefox_profiles | awk 'NF && !seen[$0]++ && system("[ -d \"" $0 "\" ]") == 0'
}

# Builds managed extension XPI path for a profile.
contra_profile_extension_path() {
  local profile_dir="$1"
  local addon_id_local="$2"
  printf '%s/extensions/%s.xpi' "${profile_dir}" "${addon_id_local}"
}

# Removes managed XPI from one Firefox profile if present.
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
is_perl_jsonpp_available() {
  command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1
}

# Validates that a policies.json file is a JSON object.
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

# Removes only Contra-managed policy keys from policies.json.
remove_addon_policy_entry() {
  local input_file="$1"
  local addon_id_value="$2"
  local output_file="$3"

  # Remove only Contra-managed policy keys and keep unrelated policy keys intact.
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
}

# Verifies targeted Contra policy keys are absent after removal.
verify_policy_uninstall() {
  local policy_file="$1"

  if [[ ! -f "${policy_file}" ]]; then
    echo "PASS: policies.json removed (no active enterprise policies in this file)."
    return 0
  fi

  if ! is_perl_jsonpp_available; then
    echo "FAIL: cannot validate uninstall because Perl JSON::PP is unavailable." >&2
    return 1
  fi

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
}

# Captures targeted policy-key state for diff-style summary.
collect_policy_state() {
  local policy_file="$1"
  local addon_id_value="$2"
  local output_file="$3"

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
}

# Reads a single key from captured policy-state file.
state_value() {
  local state_file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1==key {print substr($0, index($0, "=") + 1); exit}' "${state_file}"
}

# Tracks whether an in-place progress bar is currently displayed.
progress_line_active=false

# Renders an in-place progress bar on a single terminal line.
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
finish_progress_bar_line() {
  if [[ "${progress_line_active}" == true ]]; then
    printf '\n'
    progress_line_active=false
  fi
}

# Normalizes and adds a single unique value to a newline-separated set variable.
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

# Removes legacy runtime guard/service artifacts when present.
remove_runtime_services() {
  local runtime_dir="${CONTRA_RUNTIME_DIR_OVERRIDE:-/etc/contra}"
  local systemd_dir="${CONTRA_SYSTEMD_DIR_OVERRIDE:-/etc/systemd/system}"
  local path=""
  local unit=""

  for path in \
    "${runtime_dir}/contra-firefox-guard.sh" \
    "${runtime_dir}/contra-firefox-rescan.sh" \
    "${runtime_dir}/install-policy.sh" \
    "${runtime_dir}/contra-firefox-guard.env" \
    "${runtime_dir}/contra-firefox-rescan.env" \
    "${systemd_dir}/contra-firefox-guard.service" \
    "${systemd_dir}/contra-firefox-rescan.service" \
    "${systemd_dir}/contra-firefox-rescan.timer" \
    "/etc/contra/contra-firefox-guard.sh" \
    "/etc/contra/contra-firefox-rescan.sh" \
    "/etc/contra/install-policy.sh" \
    "/etc/contra/contra-firefox-guard.env" \
    "/etc/contra/contra-firefox-rescan.env" \
    "/etc/systemd/system/contra-firefox-guard.service" \
    "/etc/systemd/system/contra-firefox-rescan.service" \
    "/etc/systemd/system/contra-firefox-rescan.timer"; do
    [[ -e "${path}" ]] || continue
    if [[ "${EUID}" -ne 0 && ! -w "${path}" && ! -w "$(dirname "${path}")" ]]; then
      continue
    fi
    if rm -f "${path}" 2>/dev/null; then
      printf '%s\n' "${path}"
    fi
  done

  rmdir "${runtime_dir}" >/dev/null 2>&1 || true

  if command -v systemctl >/dev/null 2>&1; then
    for unit in \
      "contra-firefox-guard.service" \
      "contra-firefox-rescan.timer" \
      "contra-firefox-rescan.service"; do
      systemctl disable --now "${unit}" >/dev/null 2>&1 || true
      systemctl stop "${unit}" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  return 0
}

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
    --remove-guard)
      remove_guard=true
      shift
      ;;
    --keep-guard)
      remove_guard=false
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

if [[ -z "${addon_id}" ]]; then
  echo "--addon-id cannot be empty." >&2
  exit 1
fi

TOTAL_PROGRESS=100
render_progress_bar 3 "${TOTAL_PROGRESS}" "Preflight checks"
if [[ "${skip_admin_check}" != "1" && "${EUID}" -ne 0 ]]; then
  finish_progress_bar_line
  echo "Run as admin, for example: sudo bash scripts/uninstall-policy.sh" >&2
  exit 1
fi
os_name="$(uname -s)"

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

if ! is_perl_jsonpp_available; then
  finish_progress_bar_line
  echo "Perl JSON::PP is required for safe policy-key removal."
  exit 1
fi

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

policy_total="${#policy_files[@]}"
render_progress_bar 12 "${TOTAL_PROGRESS}" "Removing policies (0/${policy_total})"
for policy_file in "${policy_files[@]}"; do
  policy_index=$((policy_index + 1))
  policy_dir="$(dirname "${policy_file}")"
  before_state_file="${work_dir}/state-before-${policy_index}.txt"
  after_state_file="${work_dir}/state-after-${policy_index}.txt"
  updated_policy_json="${work_dir}/policies-updated-${policy_index}.json"
  remove_error_file="${work_dir}/remove-error-${policy_index}.log"
  target_result="unchanged"

  if [[ ! -f "${policy_file}" ]]; then
    missing_targets=$((missing_targets + 1))
    progress_value=$((12 + (policy_index * 58 / policy_total)))
    render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
    continue
  fi

  backup_dir="${policy_dir}/contra-policy-backups"
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  backup_path="${backup_dir}/policies-${timestamp}-${policy_index}.json"
  if ! install -d -m 0755 "${backup_dir}" || ! cp "${policy_file}" "${backup_path}" || ! chmod 0644 "${backup_path}"; then
    target_result="failed"
    failed_targets=$((failed_targets + 1))
    progress_value=$((12 + (policy_index * 58 / policy_total)))
    render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
    continue
  fi

  if ! is_policy_json_valid "${policy_file}"; then
    if ! rm -f "${policy_file}"; then
      target_result="failed"
      failed_targets=$((failed_targets + 1))
      progress_value=$((12 + (policy_index * 58 / policy_total)))
      render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
      continue
    fi
    target_result="removed"
    removed_all_targets=$((removed_all_targets + 1))
    add_unique_value files_changed "${policy_file}"
    add_unique_value policies_removed_set "unknown (invalid JSON file removed)"
    progress_value=$((12 + (policy_index * 58 / policy_total)))
    render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
    continue
  fi

  if ! collect_policy_state "${policy_file}" "${addon_id}" "${before_state_file}" 2>"${remove_error_file}"; then
    target_result="failed"
    failed_targets=$((failed_targets + 1))
    progress_value=$((12 + (policy_index * 58 / policy_total)))
    render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
    continue
  fi

  if ! remove_result="$(remove_addon_policy_entry "${policy_file}" "${addon_id}" "${updated_policy_json}" 2>"${remove_error_file}")"; then
    target_result="failed"
    failed_targets=$((failed_targets + 1))
    progress_value=$((12 + (policy_index * 58 / policy_total)))
    render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
    continue
  fi
  remove_status="$(printf '%s\n' "${remove_result}" | tail -n 1 | tr -d '[:space:]')"

  case "${remove_status}" in
    EMPTY)
      before_disable="$(state_value "${before_state_file}" "HAS_DISABLE_SAFE_MODE")"
      before_block_about_support="$(state_value "${before_state_file}" "HAS_BLOCK_ABOUT_SUPPORT")"
      before_block_about_profiles="$(state_value "${before_state_file}" "HAS_BLOCK_ABOUT_PROFILES")"
      before_distro_pref="$(state_value "${before_state_file}" "HAS_DISTRO_ADDONS_PREF")"
      before_extension="$(state_value "${before_state_file}" "HAS_EXTENSION_ENTRY")"
      before_force_adult="$(state_value "${before_state_file}" "HAS_FORCE_ADULT")"

      if [[ "${before_disable}" == "1" ]]; then add_unique_value policies_removed_set "DisableSafeMode"; fi
      if [[ "${before_block_about_support}" == "1" ]]; then add_unique_value policies_removed_set "BlockAboutSupport"; fi
      if [[ "${before_block_about_profiles}" == "1" ]]; then add_unique_value policies_removed_set "BlockAboutProfiles"; fi
      if [[ "${before_distro_pref}" == "1" ]]; then add_unique_value policies_removed_set "Preferences.extensions.installDistroAddons"; fi
      if [[ "${before_extension}" == "1" ]]; then add_unique_value policies_removed_set "ExtensionSettings[${addon_id}]"; fi
      if [[ "${before_force_adult}" == "1" ]]; then add_unique_value policies_removed_set "3rdparty.Extensions[${addon_id}].forceAdultBlock"; fi

      if ! rm -f "${policy_file}"; then
        target_result="failed"
        failed_targets=$((failed_targets + 1))
        progress_value=$((12 + (policy_index * 58 / policy_total)))
        render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
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
        progress_value=$((12 + (policy_index * 58 / policy_total)))
        render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
        continue
      fi
      target_result="updated"
      updated_targets=$((updated_targets + 1))
      add_unique_value files_changed "${policy_file}"
      ;;
    *)
      target_result="failed"
      failed_targets=$((failed_targets + 1))
      progress_value=$((12 + (policy_index * 58 / policy_total)))
      render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
      continue
      ;;
  esac

  if ! verify_policy_uninstall "${policy_file}" >/dev/null 2>&1; then
    target_result="failed"
    failed_targets=$((failed_targets + 1))
    progress_value=$((12 + (policy_index * 58 / policy_total)))
    render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
    continue
  fi

  if [[ "${target_result}" == "updated" ]]; then
    if ! collect_policy_state "${policy_file}" "${addon_id}" "${after_state_file}" 2>"${remove_error_file}"; then
      target_result="failed"
      failed_targets=$((failed_targets + 1))
      progress_value=$((12 + (policy_index * 58 / policy_total)))
      render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
      continue
    fi

    before_disable="$(state_value "${before_state_file}" "HAS_DISABLE_SAFE_MODE")"
    before_block_about_support="$(state_value "${before_state_file}" "HAS_BLOCK_ABOUT_SUPPORT")"
    before_block_about_profiles="$(state_value "${before_state_file}" "HAS_BLOCK_ABOUT_PROFILES")"
    before_distro_pref="$(state_value "${before_state_file}" "HAS_DISTRO_ADDONS_PREF")"
    before_extension="$(state_value "${before_state_file}" "HAS_EXTENSION_ENTRY")"
    before_force_adult="$(state_value "${before_state_file}" "HAS_FORCE_ADULT")"
    after_disable="$(state_value "${after_state_file}" "HAS_DISABLE_SAFE_MODE")"
    after_block_about_support="$(state_value "${after_state_file}" "HAS_BLOCK_ABOUT_SUPPORT")"
    after_block_about_profiles="$(state_value "${after_state_file}" "HAS_BLOCK_ABOUT_PROFILES")"
    after_distro_pref="$(state_value "${after_state_file}" "HAS_DISTRO_ADDONS_PREF")"
    after_extension="$(state_value "${after_state_file}" "HAS_EXTENSION_ENTRY")"
    after_force_adult="$(state_value "${after_state_file}" "HAS_FORCE_ADULT")"

    if [[ "${before_disable}" == "1" && "${after_disable}" == "0" ]]; then add_unique_value policies_removed_set "DisableSafeMode"; fi
    if [[ "${before_block_about_support}" == "1" && "${after_block_about_support}" == "0" ]]; then add_unique_value policies_removed_set "BlockAboutSupport"; fi
    if [[ "${before_block_about_profiles}" == "1" && "${after_block_about_profiles}" == "0" ]]; then add_unique_value policies_removed_set "BlockAboutProfiles"; fi
    if [[ "${before_distro_pref}" == "1" && "${after_distro_pref}" == "0" ]]; then add_unique_value policies_removed_set "Preferences.extensions.installDistroAddons"; fi
    if [[ "${before_extension}" == "1" && "${after_extension}" == "0" ]]; then add_unique_value policies_removed_set "ExtensionSettings[${addon_id}]"; fi
    if [[ "${before_force_adult}" == "1" && "${after_force_adult}" == "0" ]]; then add_unique_value policies_removed_set "3rdparty.Extensions[${addon_id}].forceAdultBlock"; fi

    if [[ "${after_disable}" == "1" ]]; then add_unique_value policies_left_set "DisableSafeMode"; fi
    if [[ "${after_block_about_support}" == "1" ]]; then add_unique_value policies_left_set "BlockAboutSupport"; fi
    if [[ "${after_block_about_profiles}" == "1" ]]; then add_unique_value policies_left_set "BlockAboutProfiles"; fi
    if [[ "${after_distro_pref}" == "1" ]]; then add_unique_value policies_left_set "Preferences.extensions.installDistroAddons"; fi
    if [[ "${after_extension}" == "1" ]]; then add_unique_value policies_left_set "ExtensionSettings[${addon_id}]"; fi
    if [[ "${after_force_adult}" == "1" ]]; then add_unique_value policies_left_set "3rdparty.Extensions[${addon_id}].forceAdultBlock"; fi

    if [[ "${after_disable}${after_block_about_support}${after_block_about_profiles}${after_distro_pref}${after_extension}${after_force_adult}" == "000000" ]]; then
      other_policies_preserved=$((other_policies_preserved + 1))
    fi
  fi

  progress_value=$((12 + (policy_index * 58 / policy_total)))
  render_progress_bar "${progress_value}" "${TOTAL_PROGRESS}" "Removing policies (${policy_index}/${policy_total})"
done

render_progress_bar 72 "${TOTAL_PROGRESS}" "Policy removal complete"
profile_removed=0
profile_missing=0
profile_failed=0
if [[ "${remove_profile_seed}" == true ]]; then
  profile_dirs=()
  while IFS= read -r profile_dir; do
    [[ -n "${profile_dir}" ]] && profile_dirs+=("${profile_dir}")
  done < <(contra_collect_firefox_profiles_unique)

  profile_total="${#profile_dirs[@]}"
  if [[ "${profile_total}" -gt 0 ]]; then
    profile_index=0
    render_progress_bar 73 "${TOTAL_PROGRESS}" "Cleaning profile seeds (0/${profile_total})"
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

render_progress_bar 95 "${TOTAL_PROGRESS}" "Cleaning runtime artifacts"
runtime_remove_failures=0
if [[ "${remove_guard}" == true ]]; then
  runtime_removed_paths="$(remove_runtime_services)" || runtime_remove_failures=1
  while IFS= read -r runtime_path; do
    [[ -n "${runtime_path}" ]] && add_unique_value files_changed "${runtime_path}"
  done <<< "${runtime_removed_paths:-}"
  if [[ "${runtime_remove_failures}" -ne 0 ]]; then
    runtime_remove_failures=1
  fi
fi

render_progress_bar 100 "${TOTAL_PROGRESS}" "Complete"
finish_progress_bar_line
echo "Policies removed by this run: $(unique_values_to_csv policies_removed_set)"
echo "Policies left after this run: $(unique_values_to_csv policies_left_set)"
echo "Files changed: $(unique_values_to_csv files_changed)"

total_failures=$((failed_targets + profile_failed + runtime_remove_failures))
if [[ "${total_failures}" -gt 0 ]]; then
  echo "Counts: policy_files(missing=${missing_targets},updated=${updated_targets},removed=${removed_all_targets},failed=${failed_targets},other_preserved=${other_policies_preserved}); profiles(removed=${profile_removed},missing=${profile_missing},failed=${profile_failed}); runtime_cleanup_failures=${runtime_remove_failures}"
  echo "Result: failure"
  exit 1
fi
echo "Result: success"
