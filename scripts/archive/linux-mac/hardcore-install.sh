#!/usr/bin/env bash
set -euo pipefail

# TEMP local ID. If publishing cleanup is requested, switch back to "contra@ltdmk".
DEFAULT_ADDON_ID="contra@local"
DEFAULT_LOCAL_XPI_PATH="/home/mik/code/contra/dist/contra@local.xpi"
addon_id="${DEFAULT_ADDON_ID}"
addon_id_explicit=false
install_url=""
source_xpi_path="${DEFAULT_LOCAL_XPI_PATH}"
source_xpi_explicit=false
on_conflict="merge"
on_conflict_explicit=false
yes_mode=false
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
skip_admin_check="${CONTRA_SKIP_ADMIN_CHECK:-0}"
force_adult_block=false
force_adult_block_explicit=false
guard_mode="enforce"
profile_seed_mode="on"
internal_rescan_run=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/firefox-policy-paths.sh
source "${SCRIPT_DIR}/lib/firefox-policy-paths.sh"
# shellcheck source=lib/firefox-profile-utils.sh
source "${SCRIPT_DIR}/lib/firefox-profile-utils.sh"

step() {
  local index="$1"
  local message="$2"
  printf '[%s/8] %s\n' "${index}" "${message}"
}

usage() {
  cat <<'USAGE'
Usage: scripts/hardcore-install.sh [options]

Install Firefox enterprise policy so Contra cannot be removed/disabled.

Options:
  --addon-id ID            Add-on ID to lock (default: contra@local)
  --source-xpi PATH        Local XPI path used for preflight/profile seeding (default: /home/mik/code/contra/dist/contra@local.xpi)
  --install-url URL        Install URL used in policy (default: file:///home/mik/code/contra/dist/contra@local.xpi)
  --on-conflict MODE       Existing policies.json behavior: merge|overwrite|abort (default: merge)
  --firefox-path PATH      Optional Firefox app/bin/install path to include (default: auto-detect)
  --adult                  Force-enable adult blocking via enterprise policy (hides toggle in UI)
  --no-adult               Do not set force adult policy flag
  --guard-mode MODE        Runtime guard mode: off|warn|enforce (default: enforce)
  --profile-seed MODE      Profile seeding mode: on|off (default: on)
  --internal-rescan-run    Internal use: skip systemd setup/reload in periodic rescan
  --yes, -y                Non-interactive mode (use selected/default options)
  -h, --help               Show help
USAGE
}

build_default_install_url() {
  local _target_addon_id="$1"
  printf 'file://%s' "${DEFAULT_LOCAL_XPI_PATH}"
}

url_decode() {
  local encoded="$1"
  encoded="${encoded//+/ }"
  printf '%b' "${encoded//%/\\x}"
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

is_perl_jsonpp_available() {
  command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1
}

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

extract_addon_id_from_xpi() {
  local xpi_path="$1"
  unzip -p "${xpi_path}" manifest.json 2>/dev/null | perl -MJSON::PP -e '
use strict;
use warnings;
local $/;
my $raw = <STDIN>;
exit 1 if !defined $raw || $raw !~ /\S/;
my $data = eval { JSON::PP::decode_json($raw) };
exit 1 if $@ || ref($data) ne "HASH";
my $id = $data->{browser_specific_settings}->{gecko}->{id};
exit 1 if !defined $id || $id eq "";
print $id;
' 2>/dev/null
}

ensure_local_install_consistency() {
  local install_url_value="$1"
  local local_path=""
  local local_path_decoded=""
  local install_source_path=""
  local xpi_addon_id=""

  case "${install_url_value}" in
    file://*)
      local_path="${install_url_value#file://}"
      local_path="${local_path#localhost/}"
      local_path="/${local_path#/}"
      local_path_decoded="$(url_decode "${local_path}")"

      if [[ ! -f "${local_path_decoded}" ]]; then
        echo "Local install file does not exist: ${local_path_decoded}" >&2
        exit 1
      fi
      if [[ ! -r "${local_path_decoded}" ]]; then
        echo "Local install file is not readable: ${local_path_decoded}" >&2
        exit 1
      fi

      install_source_path="${local_path_decoded}"
      if [[ "${source_xpi_explicit}" == true && "${source_xpi_path}" != "${install_source_path}" ]]; then
        echo "Source XPI mismatch: --source-xpi=${source_xpi_path} but --install-url points to ${install_source_path}" >&2
        exit 1
      fi

      install_url="file://${install_source_path}"
      source_xpi_path="${install_source_path}"

      if command -v unzip >/dev/null 2>&1 && is_perl_jsonpp_available; then
        if xpi_addon_id="$(extract_addon_id_from_xpi "${local_path_decoded}")" && [[ -n "${xpi_addon_id}" ]]; then
          if [[ "${addon_id_explicit}" == true && "${addon_id}" != "${xpi_addon_id}" ]]; then
            echo "Addon ID mismatch: --addon-id=${addon_id} but XPI manifest id=${xpi_addon_id}" >&2
            exit 1
          fi
          if [[ "${addon_id_explicit}" == false && "${addon_id}" != "${xpi_addon_id}" ]]; then
            echo "Using add-on ID from XPI manifest: ${xpi_addon_id}" >&2
            addon_id="${xpi_addon_id}"
          fi
        else
          echo "WARN: could not extract add-on ID from local XPI; proceeding with add-on ID ${addon_id}." >&2
        fi
      else
        echo "WARN: unzip or Perl JSON::PP unavailable; cannot validate local XPI add-on ID." >&2
      fi
      ;;
  esac
}

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

verify_policy_install() {
  local policy_file="$1"
  local expect_force_adult_flag="$2"

  if [[ ! -f "${policy_file}" ]]; then
    echo "FAIL: policy file missing at ${policy_file}" >&2
    return 1
  fi

  if is_perl_jsonpp_available; then
    perl -MJSON::PP -e '
use strict;
use warnings;

my ($path, $addon_id, $install_url, $expect_force_adult_flag) = @ARGV;

open my $fh, "<", $path or die "FAIL: could not read $path\n";
local $/;
my $raw = <$fh>;
close $fh;

my $data = eval { JSON::PP::decode_json($raw) };
if ($@) {
  die "FAIL: policies.json is not valid JSON\n";
}

if (ref($data) ne "HASH") {
  die "FAIL: policies.json top-level is not a JSON object\n";
}

if (!($data->{policies}->{DisableSafeMode} // 0)) {
  die "FAIL: DisableSafeMode is not true\n";
}

if (!($data->{policies}->{BlockAboutSupport} // 0)) {
  die "FAIL: BlockAboutSupport is not true\n";
}

if (!($data->{policies}->{BlockAboutProfiles} // 0)) {
  die "FAIL: BlockAboutProfiles is not true\n";
}

my $preferences = $data->{policies}->{Preferences};
if (ref($preferences) ne "HASH") {
  die "FAIL: missing policies.Preferences object\n";
}

my $install_pref = $preferences->{"extensions.installDistroAddons"};
if (ref($install_pref) ne "HASH") {
  die "FAIL: missing locked preferences entry for extensions.installDistroAddons\n";
}

if (!($install_pref->{Value} // 0)) {
  die "FAIL: Preferences.extensions.installDistroAddons.Value is not true\n";
}

if (($install_pref->{Status} // "") ne "locked") {
  die "FAIL: Preferences.extensions.installDistroAddons.Status is not locked\n";
}

my $settings = $data->{policies}->{ExtensionSettings};
if (ref($settings) ne "HASH") {
  die "FAIL: missing policies.ExtensionSettings object\n";
}

my $entry = $settings->{$addon_id};
if (ref($entry) ne "HASH") {
  die "FAIL: missing ExtensionSettings entry for $addon_id\n";
}

if (($entry->{installation_mode} // "") ne "force_installed") {
  die "FAIL: installation_mode is not force_installed\n";
}

if (($entry->{install_url} // "") ne $install_url) {
  die "FAIL: install_url does not match expected URL\n";
}

if (!($entry->{private_browsing} // 0)) {
  die "FAIL: private_browsing is not true\n";
}

if ($expect_force_adult_flag eq "true") {
  my $extensions = $data->{policies}->{"3rdparty"}->{Extensions};
  if (ref($extensions) ne "HASH") {
    die "FAIL: missing policies.3rdparty.Extensions for forced adult policy\n";
  }

  my $managed = $extensions->{$addon_id};
  if (ref($managed) ne "HASH") {
    die "FAIL: missing managed policy block for $addon_id\n";
  }

  if (!($managed->{forceAdultBlock} // 0)) {
    die "FAIL: forceAdultBlock is not true in managed policy\n";
  }
}

print "PASS: policies.json is valid and Contra force-install policy is active.\n";
' "${policy_file}" "${addon_id}" "${install_url}" "${expect_force_adult_flag}"
    return 0
  fi

  echo "WARN: Perl JSON::PP not available; running basic fallback checks only." >&2
  if ! grep -Fq '"ExtensionSettings"' "${policy_file}"; then
    echo "FAIL: missing ExtensionSettings in ${policy_file}" >&2
    return 1
  fi
  if ! grep -Eq '"DisableSafeMode"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: DisableSafeMode is not true in ${policy_file}" >&2
    return 1
  fi
  if ! grep -Eq '"BlockAboutSupport"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: BlockAboutSupport is not true in ${policy_file}" >&2
    return 1
  fi
  if ! grep -Eq '"BlockAboutProfiles"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: BlockAboutProfiles is not true in ${policy_file}" >&2
    return 1
  fi
  if ! grep -Fq '"extensions.installDistroAddons"' "${policy_file}"; then
    echo "FAIL: missing Preferences.extensions.installDistroAddons in ${policy_file}" >&2
    return 1
  fi
  if ! grep -Eq '"Status"[[:space:]]*:[[:space:]]*"locked"' "${policy_file}"; then
    echo "FAIL: Preferences lock status is not set to locked in ${policy_file}" >&2
    return 1
  fi
  if ! grep -Fq "\"${addon_id}\"" "${policy_file}"; then
    echo "FAIL: missing add-on entry ${addon_id} in ${policy_file}" >&2
    return 1
  fi
  if ! grep -Fq '"installation_mode": "force_installed"' "${policy_file}"; then
    echo "FAIL: installation_mode is not force_installed" >&2
    return 1
  fi
  if ! grep -Fq "\"install_url\": \"${install_url}\"" "${policy_file}"; then
    echo "FAIL: install_url mismatch in ${policy_file}" >&2
    return 1
  fi
  if ! grep -Eq '"private_browsing"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: private_browsing is not true in ${policy_file}" >&2
    return 1
  fi

  if [[ "${expect_force_adult_flag}" == "true" ]]; then
    if ! grep -Fq '"3rdparty"' "${policy_file}"; then
      echo "FAIL: missing 3rdparty policy section in ${policy_file}" >&2
      return 1
    fi
    if ! grep -Fq "\"${addon_id}\"" "${policy_file}"; then
      echo "FAIL: missing managed add-on entry ${addon_id} in ${policy_file}" >&2
      return 1
    fi
    if ! grep -Eq '"forceAdultBlock"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
      echo "FAIL: forceAdultBlock is not true in ${policy_file}" >&2
      return 1
    fi
  fi

  echo "PASS: basic policy checks passed (JSON parser unavailable for deep validation)."
}

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

state_value() {
  local state_file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1==key {print substr($0, index($0, "=") + 1); exit}' "${state_file}"
}

normalize_guard_mode() {
  local raw_mode="${1,,}"
  case "${raw_mode}" in
    off|warn|enforce)
      printf '%s' "${raw_mode}"
      ;;
    *)
      return 1
      ;;
  esac
}

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

write_guard_env_file() {
  local guard_env_file="/etc/contra/contra-firefox-guard.env"
  install -d -m 0755 "/etc/contra"
  cat > "${guard_env_file}" <<EOF_GUARD_ENV
ADDON_ID="${addon_id}"
SOURCE_XPI="${source_xpi_path}"
GUARD_MODE="${guard_mode}"
SCAN_INTERVAL_SECONDS="2"
EOF_GUARD_ENV
  chmod 0644 "${guard_env_file}"
}

write_rescan_env_file() {
  local rescan_env_file="/etc/contra/contra-firefox-rescan.env"
  install -d -m 0755 "/etc/contra"
  cat > "${rescan_env_file}" <<EOF_RESCAN_ENV
ADDON_ID="${addon_id}"
SOURCE_XPI="${source_xpi_path}"
INSTALL_URL="${install_url}"
GUARD_MODE="${guard_mode}"
EOF_RESCAN_ENV
  chmod 0644 "${rescan_env_file}"
}

render_systemd_template() {
  local template_file="$1"
  local output_file="$2"
  sed "s|__CONTRA_REPO_SCRIPTS_DIR__|${SCRIPT_DIR}|g" "${template_file}" > "${output_file}"
}

setup_runtime_services() {
  local guard_service_name="contra-firefox-guard.service"
  local rescan_service_name="contra-firefox-rescan.service"
  local rescan_timer_name="contra-firefox-rescan.timer"
  local systemd_dir="/etc/systemd/system"
  local guard_template="${SCRIPT_DIR}/../deploy/systemd/contra-firefox-guard.service"
  local rescan_service_template="${SCRIPT_DIR}/../deploy/systemd/contra-firefox-rescan.service"
  local rescan_timer_template="${SCRIPT_DIR}/../deploy/systemd/contra-firefox-rescan.timer"
  local failed=false

  if [[ "${internal_rescan_run}" == true ]]; then
    echo "Runtime services: skipped (internal rescan run)."
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARN: systemctl is unavailable; skipping guard and rescan timer setup." >&2
    return 0
  fi

  if [[ ! -f "${guard_template}" || ! -f "${rescan_service_template}" || ! -f "${rescan_timer_template}" ]]; then
    echo "WARN: missing systemd templates in deploy/systemd; skipping runtime service setup." >&2
    return 0
  fi

  if ! install -d -m 0755 "${systemd_dir}"; then
    echo "ERROR: could not create ${systemd_dir}" >&2
    return 1
  fi

  if ! render_systemd_template "${guard_template}" "${systemd_dir}/${guard_service_name}"; then
    echo "ERROR: failed to render ${guard_service_name}" >&2
    failed=true
  fi
  if ! render_systemd_template "${rescan_service_template}" "${systemd_dir}/${rescan_service_name}"; then
    echo "ERROR: failed to render ${rescan_service_name}" >&2
    failed=true
  fi
  if ! cp "${rescan_timer_template}" "${systemd_dir}/${rescan_timer_name}"; then
    echo "ERROR: failed to install ${rescan_timer_name}" >&2
    failed=true
  fi

  if [[ "${failed}" == true ]]; then
    return 1
  fi

  write_guard_env_file
  write_rescan_env_file

  if ! systemctl daemon-reload >/dev/null 2>&1; then
    echo "ERROR: systemctl daemon-reload failed." >&2
    return 1
  fi

  if [[ "${guard_mode}" == "off" ]]; then
    systemctl disable --now "${guard_service_name}" >/dev/null 2>&1 || true
    echo "Guard service: disabled (guard mode off)."
  else
    if ! systemctl enable --now "${guard_service_name}" >/dev/null 2>&1; then
      echo "ERROR: failed to enable/start ${guard_service_name}" >&2
      return 1
    fi
    echo "Guard service: enabled (${guard_mode})."
  fi

  if ! systemctl enable --now "${rescan_timer_name}" >/dev/null 2>&1; then
    echo "ERROR: failed to enable/start ${rescan_timer_name}" >&2
    return 1
  fi
  echo "Rescan timer: enabled (${rescan_timer_name})."

  return 0
}

if [[ $# -eq 0 ]]; then
  :
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --addon-id)
      addon_id="${2:-}"
      addon_id_explicit=true
      shift 2
      ;;
    --addon-id=*)
      addon_id="${1#*=}"
      addon_id_explicit=true
      shift
      ;;
    --source-xpi)
      source_xpi_path="${2:-}"
      source_xpi_explicit=true
      shift 2
      ;;
    --source-xpi=*)
      source_xpi_path="${1#*=}"
      source_xpi_explicit=true
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
    --guard-mode)
      guard_mode="${2:-}"
      shift 2
      ;;
    --guard-mode=*)
      guard_mode="${1#*=}"
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
    --internal-rescan-run)
      internal_rescan_run=true
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

if [[ -z "${source_xpi_path}" ]]; then
  echo "--source-xpi cannot be empty." >&2
  exit 1
fi

if ! guard_mode="$(normalize_guard_mode "${guard_mode}")"; then
  echo "Invalid --guard-mode value: ${guard_mode}. Use off|warn|enforce." >&2
  exit 1
fi

if ! profile_seed_mode="$(normalize_profile_seed_mode "${profile_seed_mode}")"; then
  echo "Invalid --profile-seed value: ${profile_seed_mode}. Use on|off." >&2
  exit 1
fi

on_conflict="${on_conflict,,}"
case "${on_conflict}" in
  merge|overwrite|abort)
    ;;
  *)
    echo "Invalid --on-conflict value: ${on_conflict}. Use merge|overwrite|abort." >&2
    exit 1
    ;;
esac

if [[ -z "${install_url}" ]]; then
  install_url="$(build_default_install_url "${addon_id}")"
fi

if [[ "${install_url}" != file://* ]]; then
  echo "--install-url must start with file:// for testing-phase Hardcore Mode." >&2
  exit 1
fi

ensure_local_install_consistency "${install_url}"

if [[ ! -f "${source_xpi_path}" || ! -r "${source_xpi_path}" ]]; then
  echo "Source XPI is missing or unreadable: ${source_xpi_path}" >&2
  exit 1
fi

step 1 "Checking admin permissions and prerequisites"
if [[ "${skip_admin_check}" != "1" && "${EUID}" -ne 0 ]]; then
  echo "Run as admin. Example: sudo scripts/hardcore-install.sh" >&2
  exit 1
fi

os_name="$(uname -s)"
if [[ "${on_conflict}" == "merge" ]] && ! is_perl_jsonpp_available; then
  echo "Merge mode needs Perl JSON::PP, but it is unavailable on this machine." >&2
  if [[ "${yes_mode}" == true ]]; then
    echo "Non-interactive mode cannot prompt for fallback. Re-run with --on-conflict overwrite or install Perl JSON::PP." >&2
    exit 1
  fi
  on_conflict="$(choose_conflict_mode_without_merge)"
fi

effective_conflict_mode="${on_conflict}"

step 2 "Detecting Firefox policy locations"
policy_files=()
while IFS= read -r policy_candidate; do
  if [[ -n "${policy_candidate}" ]]; then
    policy_files+=("${policy_candidate}")
  fi
done < <(contra_collect_policy_files "${os_name}" "${firefox_path}" "${policy_file_override}")

if [[ ${#policy_files[@]} -eq 0 ]]; then
  echo "Could not determine any Firefox policy file targets." >&2
  exit 1
fi

echo "Policy file targets:"
for policy_file in "${policy_files[@]}"; do
  echo "  - ${policy_file}"
done
echo "Add-on ID: ${addon_id}"
echo "Install URL: ${install_url}"
echo "Source XPI: ${source_xpi_path}"
echo "Force adult policy: ${force_adult_block}"
echo "Profile seeding: ${profile_seed_mode}"
echo "Guard mode: ${guard_mode}"

step 3 "Preparing Contra policy payload"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

target_policy_json="${work_dir}/contra-policy-target.json"
render_target_policy_json "${target_policy_json}"

prompted_conflict_choice=false
policy_index=0
failed_targets=0
updated_targets=0
created_targets=0
installed_policy_list="DisableSafeMode, BlockAboutSupport, BlockAboutProfiles, Preferences.extensions.installDistroAddons{Value=true,Status=locked}, ExtensionSettings[${addon_id}]{installation_mode,install_url,private_browsing}"
if [[ "${force_adult_block}" == true ]]; then
  installed_policy_list+=", 3rdparty.Extensions[${addon_id}].forceAdultBlock"
fi

step 4 "Applying policy updates"
for policy_file in "${policy_files[@]}"; do
  policy_index=$((policy_index + 1))
  policy_dir="$(dirname "${policy_file}")"
  final_policy_json="${work_dir}/contra-policy-final-${policy_index}.json"
  merge_error_file="${work_dir}/merge-error-${policy_index}.log"
  state_file="${work_dir}/state-${policy_index}.txt"
  file_existed=false
  applied_mode="create"

  echo "Target: ${policy_file}"

  if [[ -f "${policy_file}" ]]; then
    file_existed=true
    backup_dir="${policy_dir}/contra-policy-backups"
    timestamp="$(date -u +%Y%m%d%H%M%S)"
    backup_path="${backup_dir}/policies-${timestamp}-${policy_index}.json"

    install -d -m 0755 "${backup_dir}"
    cp "${policy_file}" "${backup_path}"
    chmod 0644 "${backup_path}"
    echo "  Backup: ${backup_path}"

    if ! is_policy_json_valid "${policy_file}"; then
      if ! rm -f "${policy_file}"; then
        echo "  ERROR: invalid JSON detected but failed to delete corrupted file ${policy_file}"
        failed_targets=$((failed_targets + 1))
        continue
      fi
      cp "${target_policy_json}" "${final_policy_json}"
      applied_mode="create (deleted invalid JSON file)"
      file_existed=false
      echo "  Invalid JSON detected; deleted corrupted policies file."
    else
      if [[ "${on_conflict_explicit}" == false && "${yes_mode}" == false && "${prompted_conflict_choice}" == false ]]; then
        effective_conflict_mode="$(choose_conflict_mode_interactive)"
        prompted_conflict_choice=true
      fi

      case "${effective_conflict_mode}" in
        abort)
          echo "  Install aborted by user choice."
          exit 0
          ;;
        overwrite)
          cp "${target_policy_json}" "${final_policy_json}"
          applied_mode="overwrite"
          ;;
        merge)
          if merge_policy_json_with_existing \
            "${policy_file}" \
            "${final_policy_json}" \
            "${force_adult_block}" \
            "${force_adult_block_explicit}" \
            2>"${merge_error_file}"; then
            applied_mode="merge"
          else
            cp "${target_policy_json}" "${final_policy_json}"
            applied_mode="overwrite (merge failed)"
            echo "  WARN: merge failed, used overwrite fallback: $(tr '\n' ' ' < "${merge_error_file}")"
          fi
          ;;
      esac
    fi
  else
    cp "${target_policy_json}" "${final_policy_json}"
  fi

  if ! install -d -m 0755 "${policy_dir}"; then
    echo "  ERROR: could not create policy directory ${policy_dir}"
    failed_targets=$((failed_targets + 1))
    continue
  fi

  if ! install -m 0644 "${final_policy_json}" "${policy_file}"; then
    echo "  ERROR: could not write ${policy_file}"
    failed_targets=$((failed_targets + 1))
    continue
  fi

  if ! verify_policy_install "${policy_file}" "${force_adult_block}" >/dev/null 2>&1; then
    echo "  ERROR: verification failed for ${policy_file}"
    failed_targets=$((failed_targets + 1))
    continue
  fi

  if ! collect_policy_state "${policy_file}" "${addon_id}" "${state_file}"; then
    echo "  ERROR: unable to read final policy state for ${policy_file}"
    failed_targets=$((failed_targets + 1))
    continue
  fi

  policy_keys_left="$(state_value "${state_file}" "POLICY_KEYS")"
  echo "  Installed policies: ${installed_policy_list}"
  echo "  Policies left in file: ${policy_keys_left}"
  echo "  Action used: ${applied_mode}"

  if [[ "${file_existed}" == true ]]; then
    updated_targets=$((updated_targets + 1))
  else
    created_targets=$((created_targets + 1))
  fi
done

profile_seeded=0
profile_updated=0
profile_up_to_date=0
profile_failed=0

step 5 "Seeding Firefox profiles"
if [[ "${profile_seed_mode}" == "on" ]]; then
  while IFS= read -r profile_dir; do
    if [[ -z "${profile_dir}" ]]; then
      continue
    fi

    seed_result="$(contra_seed_profile_xpi "${profile_dir}" "${source_xpi_path}" "${addon_id}")" || true
    seed_status="${seed_result%%|*}"
    seed_remainder="${seed_result#*|}"
    seed_profile="${seed_remainder%%|*}"
    seed_path="${seed_remainder#*|}"

    case "${seed_status}" in
      seeded)
        profile_seeded=$((profile_seeded + 1))
        echo "Profile seeded: ${seed_profile} -> ${seed_path}"
        ;;
      updated)
        profile_updated=$((profile_updated + 1))
        echo "Profile updated: ${seed_profile} -> ${seed_path}"
        ;;
      "already up-to-date")
        profile_up_to_date=$((profile_up_to_date + 1))
        echo "Profile already up-to-date: ${seed_profile} -> ${seed_path}"
        ;;
      failed)
        profile_failed=$((profile_failed + 1))
        echo "Profile seed failed: ${seed_profile} (${seed_path})"
        ;;
      *)
        profile_failed=$((profile_failed + 1))
        echo "Profile seed failed: ${profile_dir} (unknown status: ${seed_status})"
        ;;
    esac
  done < <(contra_collect_firefox_profiles_unique)
else
  echo "Profile seeding skipped (--profile-seed off)."
fi

step 6 "Configuring runtime guard and rescan timer"
service_setup_failed=0
if ! setup_runtime_services; then
  service_setup_failed=1
  echo "Runtime service setup failed."
else
  echo "Runtime service setup complete."
fi

step 7 "Install summary"
echo "Created policy files: ${created_targets}"
echo "Updated policy files: ${updated_targets}"
echo "Failed policy files: ${failed_targets}"
echo "Profiles seeded: ${profile_seeded}"
echo "Profiles updated: ${profile_updated}"
echo "Profiles already up-to-date: ${profile_up_to_date}"
echo "Profiles failed: ${profile_failed}"
echo "Runtime service setup failures: ${service_setup_failed}"

step 8 "Result"
total_failures=$((failed_targets + profile_failed + service_setup_failed))
if [[ "${total_failures}" -gt 0 ]]; then
  echo "Hardcore Mode install finished with errors."
  echo "Fix failed targets and re-run install."
  exit 1
fi

echo "Hardcore Mode install complete."
echo "Next steps:"
echo "  1. Restart Firefox completely."
echo "  2. Open about:policies and confirm Status is Active."
echo "  3. Confirm ExtensionSettings contains ${addon_id}."
echo "  4. Confirm DisableSafeMode, BlockAboutSupport, and BlockAboutProfiles are true."
