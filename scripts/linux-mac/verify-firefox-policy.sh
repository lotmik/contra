#!/usr/bin/env bash
set -euo pipefail

# TEMP local ID. If publishing cleanup is requested, switch back to "contra@ltdmk".
DEFAULT_ADDON_ID="contra@local"
DEFAULT_LOCAL_XPI_PATH="/home/mik/code/contra/dist/contra@local.xpi"
addon_id="${DEFAULT_ADDON_ID}"
install_url="file://${DEFAULT_LOCAL_XPI_PATH}"
source_xpi_path="${DEFAULT_LOCAL_XPI_PATH}"
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
force_adult_block=false
strict_runtime=false
guard_mode="enforce"
profile_seed_mode="on"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/firefox-policy-paths.sh
source "${SCRIPT_DIR}/lib/firefox-policy-paths.sh"
# shellcheck source=lib/firefox-profile-utils.sh
source "${SCRIPT_DIR}/lib/firefox-profile-utils.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/verify-firefox-policy.sh [options]

Verify Firefox enterprise policy, profile-seeded extension state, and optional runtime guard.

Options:
  --addon-id ID            Add-on ID to verify (default: contra@local)
  --install-url URL        Expected install URL (default: file:///home/mik/code/contra/dist/contra@local.xpi)
  --source-xpi PATH        Expected local XPI path for profile seeding (default: /home/mik/code/contra/dist/contra@local.xpi)
  --firefox-path PATH      Optional Firefox app/bin/install path to include (default: auto-detect)
  --adult                  Verify force adult policy flag is present and true
  --no-adult               Verify force adult policy flag is absent/ignored
  --profile-seed MODE      Verify profile-seeded extension files: on|off (default: on)
  --strict-runtime         Verify guard/timer services and run guard check-only scan
  --guard-mode MODE        Expected guard mode for strict runtime: off|warn|enforce (default: enforce)
  -h, --help               Show help
USAGE
}

is_perl_jsonpp_available() {
  command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1
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

verify_policy_file() {
  local policy_file="$1"
  local expect_force_adult_flag="$2"

  if [[ ! -f "${policy_file}" ]]; then
    echo "FAIL: policy file missing: ${policy_file}"
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
  die "FAIL: policies.json is invalid JSON\n";
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
  die "FAIL: missing Preferences.extensions.installDistroAddons entry\n";
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

print "PASS\n";
' "${policy_file}" "${addon_id}" "${install_url}" "${expect_force_adult_flag}" >/dev/null
    return 0
  fi

  if ! grep -Eq '"DisableSafeMode"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: DisableSafeMode is not true in ${policy_file}"
    return 1
  fi
  if ! grep -Eq '"BlockAboutSupport"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: BlockAboutSupport is not true in ${policy_file}"
    return 1
  fi
  if ! grep -Eq '"BlockAboutProfiles"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: BlockAboutProfiles is not true in ${policy_file}"
    return 1
  fi
  if ! grep -Fq "\"${addon_id}\"" "${policy_file}"; then
    echo "FAIL: missing add-on entry ${addon_id} in ${policy_file}"
    return 1
  fi
  if ! grep -Fq '"installation_mode": "force_installed"' "${policy_file}"; then
    echo "FAIL: installation_mode is not force_installed in ${policy_file}"
    return 1
  fi
  if ! grep -Fq "\"install_url\": \"${install_url}\"" "${policy_file}"; then
    echo "FAIL: install_url mismatch in ${policy_file}"
    return 1
  fi
  if ! grep -Eq '"private_browsing"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: private_browsing is not true in ${policy_file}"
    return 1
  fi
  if ! grep -Fq '"extensions.installDistroAddons"' "${policy_file}"; then
    echo "FAIL: missing Preferences.extensions.installDistroAddons in ${policy_file}"
    return 1
  fi
  if ! grep -Eq '"Status"[[:space:]]*:[[:space:]]*"locked"' "${policy_file}"; then
    echo "FAIL: preferences lock status missing in ${policy_file}"
    return 1
  fi

  if [[ "${expect_force_adult_flag}" == "true" ]]; then
    if ! grep -Eq '"forceAdultBlock"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
      echo "FAIL: forceAdultBlock is not true in ${policy_file}"
      return 1
    fi
  fi

  return 0
}

verify_profile_seed_state() {
  local profile_dir="$1"
  local state=""
  state="$(contra_check_profile_addon_runtime_state "${profile_dir}" "${addon_id}")" || {
    echo "FAIL: profile ${profile_dir} is non-compliant (${state})"
    return 1
  }
  echo "PASS: profile ${profile_dir} has compliant seeded extension state."
  return 0
}

verify_runtime_services() {
  local failures=0
  local guard_service="contra-firefox-guard.service"
  local rescan_timer="contra-firefox-rescan.timer"
  local guard_env="/etc/contra/contra-firefox-guard.env"

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "FAIL: systemctl unavailable; cannot run strict runtime checks."
    return 1
  fi

  if [[ "${guard_mode}" == "off" ]]; then
    if systemctl is-active --quiet "${guard_service}"; then
      echo "FAIL: ${guard_service} is active but expected off."
      failures=$((failures + 1))
    else
      echo "PASS: ${guard_service} is inactive (expected for guard mode off)."
    fi
  else
    if ! systemctl is-active --quiet "${guard_service}"; then
      echo "FAIL: ${guard_service} is not active."
      failures=$((failures + 1))
    else
      echo "PASS: ${guard_service} is active."
    fi
  fi

  if ! systemctl is-active --quiet "${rescan_timer}"; then
    echo "FAIL: ${rescan_timer} is not active."
    failures=$((failures + 1))
  else
    echo "PASS: ${rescan_timer} is active."
  fi

  if [[ -f "${guard_env}" ]]; then
    if ! grep -Eq '^GUARD_MODE="'${guard_mode}'"$' "${guard_env}"; then
      echo "FAIL: ${guard_env} guard mode does not match expected mode (${guard_mode})."
      failures=$((failures + 1))
    else
      echo "PASS: ${guard_env} guard mode matches ${guard_mode}."
    fi
  else
    echo "FAIL: missing runtime guard env file ${guard_env}."
    failures=$((failures + 1))
  fi

  if ! "${SCRIPT_DIR}/contra-firefox-guard.sh" --once --check-only --mode "${guard_mode}" --addon-id "${addon_id}"; then
    echo "FAIL: guard check-only scan reported runtime violations."
    failures=$((failures + 1))
  else
    echo "PASS: guard check-only scan reports no runtime violations."
  fi

  if [[ "${failures}" -gt 0 ]]; then
    return 1
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
    --install-url)
      install_url="${2:-}"
      shift 2
      ;;
    --install-url=*)
      install_url="${1#*=}"
      shift
      ;;
    --source-xpi)
      source_xpi_path="${2:-}"
      shift 2
      ;;
    --source-xpi=*)
      source_xpi_path="${1#*=}"
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
    --adult)
      force_adult_block=true
      shift
      ;;
    --no-adult)
      force_adult_block=false
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
    --strict-runtime)
      strict_runtime=true
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
if ! profile_seed_mode="$(normalize_profile_seed_mode "${profile_seed_mode}")"; then
  echo "Invalid --profile-seed value: ${profile_seed_mode}. Use on|off." >&2
  exit 1
fi
if ! guard_mode="$(normalize_guard_mode "${guard_mode}")"; then
  echo "Invalid --guard-mode value: ${guard_mode}. Use off|warn|enforce." >&2
  exit 1
fi
if [[ "${install_url}" != file://* ]]; then
  echo "--install-url must start with file:// in testing phase." >&2
  exit 1
fi
if [[ ! -f "${source_xpi_path}" || ! -r "${source_xpi_path}" ]]; then
  echo "FAIL: source XPI is missing or unreadable: ${source_xpi_path}" >&2
  exit 1
fi

os_name="$(uname -s)"
policy_files=()
while IFS= read -r policy_candidate; do
  if [[ -n "${policy_candidate}" ]]; then
    policy_files+=("${policy_candidate}")
  fi
done < <(contra_collect_policy_files "${os_name}" "${firefox_path}" "${policy_file_override}")

if [[ ${#policy_files[@]} -eq 0 ]]; then
  echo "FAIL: could not determine any Firefox policy file targets." >&2
  exit 1
fi

echo "Policy targets:"
for policy_file in "${policy_files[@]}"; do
  echo "  - ${policy_file}"
done
echo "Add-on ID: ${addon_id}"
echo "Expected install URL: ${install_url}"
echo "Expected source XPI: ${source_xpi_path}"
echo "Expect force adult policy: ${force_adult_block}"
echo "Profile seed check: ${profile_seed_mode}"
echo "Strict runtime check: ${strict_runtime}"
echo "Expected guard mode: ${guard_mode}"

policy_failures=0
for policy_file in "${policy_files[@]}"; do
  if verify_policy_file "${policy_file}" "${force_adult_block}"; then
    echo "PASS: policy target verified: ${policy_file}"
  else
    policy_failures=$((policy_failures + 1))
    echo "FAIL: policy target verification failed: ${policy_file}"
  fi
done

profile_failures=0
profile_checked=0
if [[ "${profile_seed_mode}" == "on" ]]; then
  while IFS= read -r profile_dir; do
    if [[ -z "${profile_dir}" ]]; then
      continue
    fi
    profile_checked=$((profile_checked + 1))
    if ! verify_profile_seed_state "${profile_dir}"; then
      profile_failures=$((profile_failures + 1))
    fi
  done < <(contra_collect_firefox_profiles_unique)
fi

runtime_failures=0
if [[ "${strict_runtime}" == true ]]; then
  if ! verify_runtime_services; then
    runtime_failures=1
  fi
fi

echo "Summary:"
echo "  Policy failures: ${policy_failures}"
echo "  Profiles checked: ${profile_checked}"
echo "  Profile failures: ${profile_failures}"
echo "  Runtime failures: ${runtime_failures}"

if [[ $((policy_failures + profile_failures + runtime_failures)) -gt 0 ]]; then
  exit 1
fi

echo "PASS: all requested checks succeeded."
