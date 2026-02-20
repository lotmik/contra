#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ADDON_ID="contra@lotmik"
addon_id="${DEFAULT_ADDON_ID}"
install_url=""
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
force_adult_block=false

usage() {
  cat <<'USAGE'
Usage: scripts/verify-firefox-policy.sh [options]

Verify Firefox enterprise policy for Contra Hardcore Mode.

Options:
  --addon-id ID            Add-on ID to verify (default: contra@lotmik)
  --install-url URL        Expected install URL (default: AMO latest URL from add-on ID)
  --firefox-path PATH      macOS: Firefox .app path (default: auto-detect)
  --adult                  Verify force adult policy flag is present and true
  --no-adult               Verify only force-install/private-browsing policy
  -h, --help               Show help
USAGE
}

url_encode() {
  local raw="$1"
  local encoded=""
  local index ch hex

  for ((index = 0; index < ${#raw}; index += 1)); do
    ch="${raw:index:1}"
    case "${ch}" in
      [a-zA-Z0-9.~_-])
        encoded+="${ch}"
        ;;
      *)
        printf -v hex '%%%02X' "'${ch}"
        encoded+="${hex}"
        ;;
    esac
  done

  printf '%s' "${encoded}"
}

build_default_install_url() {
  local target_addon_id="$1"
  local encoded
  encoded="$(url_encode "${target_addon_id}")"
  printf 'https://addons.mozilla.org/firefox/downloads/latest/%s/latest.xpi' "${encoded}"
}

is_perl_jsonpp_available() {
  command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1
}

resolve_policy_file() {
  local os_name="$1"

  if [[ -n "${policy_file_override}" ]]; then
    printf '%s' "${policy_file_override}"
    return 0
  fi

  if [[ "${os_name}" == "Linux" ]]; then
    printf '%s' '/etc/firefox/policies/policies.json'
    return 0
  fi

  if [[ "${os_name}" != "Darwin" ]]; then
    echo "Unsupported operating system: ${os_name}" >&2
    echo "Use scripts/hardcore-install.ps1 on Windows." >&2
    return 1
  fi

  local app_path=""
  if [[ -n "${firefox_path}" ]]; then
    case "${firefox_path}" in
      *.app)
        app_path="${firefox_path}"
        ;;
      */Contents/MacOS/firefox)
        app_path="${firefox_path%/Contents/MacOS/firefox}"
        ;;
      */Contents/Resources/distribution)
        app_path="${firefox_path%/Contents/Resources/distribution}"
        ;;
      *)
        if [[ -d "${firefox_path}/Contents/Resources" ]]; then
          app_path="${firefox_path}"
        fi
        ;;
    esac
  fi

  if [[ -z "${app_path}" ]]; then
    local candidates=(
      "/Applications/Firefox.app"
      "/Applications/Firefox Developer Edition.app"
      "/Applications/Firefox Nightly.app"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
      if [[ -d "${candidate}" ]]; then
        app_path="${candidate}"
        break
      fi
    done
  fi

  if [[ -z "${app_path}" ]]; then
    echo "Could not locate Firefox.app." >&2
    echo "Pass --firefox-path '/Applications/Firefox.app' (or your custom Firefox .app path)." >&2
    return 1
  fi

  printf '%s' "${app_path}/Contents/Resources/distribution/policies.json"
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

if [[ -z "${install_url}" ]]; then
  install_url="$(build_default_install_url "${addon_id}")"
fi

os_name="$(uname -s)"
policy_file="$(resolve_policy_file "${os_name}")"

echo "Policy file: ${policy_file}"
echo "Add-on ID: ${addon_id}"
echo "Expected install URL: ${install_url}"
echo "Expect force adult policy: ${force_adult_block}"

if [[ ! -f "${policy_file}" ]]; then
  echo "FAIL: policy file does not exist." >&2
  exit 1
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
' "${policy_file}" "${addon_id}" "${install_url}" "${force_adult_block}"
else
  echo "WARN: Perl JSON::PP not available; running basic fallback checks only." >&2

  if ! grep -Fq '"ExtensionSettings"' "${policy_file}"; then
    echo "FAIL: missing ExtensionSettings in ${policy_file}" >&2
    exit 1
  fi
  if ! grep -Fq "\"${addon_id}\"" "${policy_file}"; then
    echo "FAIL: missing add-on entry ${addon_id} in ${policy_file}" >&2
    exit 1
  fi
  if ! grep -Fq '"installation_mode": "force_installed"' "${policy_file}"; then
    echo "FAIL: installation_mode is not force_installed" >&2
    exit 1
  fi
  if ! grep -Fq "\"install_url\": \"${install_url}\"" "${policy_file}"; then
    echo "FAIL: install_url mismatch in ${policy_file}" >&2
    exit 1
  fi
  if ! grep -Eq '"private_browsing"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
    echo "FAIL: private_browsing is not true in ${policy_file}" >&2
    exit 1
  fi

  if [[ "${force_adult_block}" == "true" ]]; then
    if ! grep -Fq '"3rdparty"' "${policy_file}"; then
      echo "FAIL: missing 3rdparty policy section in ${policy_file}" >&2
      exit 1
    fi
    if ! grep -Fq "\"${addon_id}\"" "${policy_file}"; then
      echo "FAIL: missing managed add-on entry ${addon_id} in ${policy_file}" >&2
      exit 1
    fi
    if ! grep -Eq '"forceAdultBlock"[[:space:]]*:[[:space:]]*true' "${policy_file}"; then
      echo "FAIL: forceAdultBlock is not true in ${policy_file}" >&2
      exit 1
    fi
  fi

  echo "PASS: basic policy checks passed (JSON parser unavailable for deep validation)."
fi

echo "Manual confirmation: restart Firefox and verify about:policies shows Active."
