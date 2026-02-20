#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ADDON_ID="contra@lotmik"
addon_id="${DEFAULT_ADDON_ID}"
install_url=""
on_conflict="merge"
on_conflict_explicit=false
yes_mode=false
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
skip_admin_check="${CONTRA_SKIP_ADMIN_CHECK:-0}"

step() {
  local index="$1"
  local message="$2"
  printf '[%s/6] %s\n' "${index}" "${message}"
}

usage() {
  cat <<'USAGE'
Usage: scripts/hardcore-install.sh [options]

Install Firefox enterprise policy so Contra cannot be removed/disabled.

Options:
  --addon-id ID            Add-on ID to lock (default: contra@lotmik)
  --install-url URL        Install URL used in policy (default: AMO latest URL from add-on ID)
  --on-conflict MODE       Existing policies.json behavior: merge|overwrite|abort (default: merge)
  --firefox-path PATH      macOS: Firefox .app path (default: auto-detect)
  --yes, -y                Non-interactive mode (use selected/default options)
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

render_target_policy_json() {
  local output_file="$1"
  local addon_id_escaped install_url_escaped
  addon_id_escaped="$(json_escape "${addon_id}")"
  install_url_escaped="$(json_escape "${install_url}")"

  cat > "${output_file}" <<EOF_JSON
{
  "policies": {
    "ExtensionSettings": {
      "${addon_id_escaped}": {
        "installation_mode": "force_installed",
        "install_url": "${install_url_escaped}"
      }
    }
  }
}
EOF_JSON
}

merge_policy_json_with_existing() {
  local existing_policy_file="$1"
  local merged_output_file="$2"

  perl -MJSON::PP -e '
use strict;
use warnings;

my ($existing_path, $addon_id, $install_url, $output_path) = @ARGV;

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
$data->{policies}->{ExtensionSettings} = {}
  if !exists $data->{policies}->{ExtensionSettings} || ref($data->{policies}->{ExtensionSettings}) ne "HASH";

$data->{policies}->{ExtensionSettings}->{$addon_id} = {
  installation_mode => "force_installed",
  install_url => $install_url,
};

open my $out_fh, ">", $output_path or die "Failed to write merged policy output.\n";
print {$out_fh} JSON::PP->new->utf8->canonical->pretty->encode($data);
close $out_fh or die "Failed to finalize merged policy output.\n";
' "${existing_policy_file}" "${addon_id}" "${install_url}" "${merged_output_file}"
}

verify_policy_install() {
  local policy_file="$1"

  if [[ ! -f "${policy_file}" ]]; then
    echo "FAIL: policy file missing at ${policy_file}" >&2
    return 1
  fi

  if is_perl_jsonpp_available; then
    perl -MJSON::PP -e '
use strict;
use warnings;

my ($path, $addon_id, $install_url) = @ARGV;

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

print "PASS: policies.json is valid and Contra force-install policy is active.\n";
' "${policy_file}" "${addon_id}" "${install_url}"
    return 0
  fi

  echo "WARN: Perl JSON::PP not available; running basic fallback checks only." >&2
  if ! grep -Fq '"ExtensionSettings"' "${policy_file}"; then
    echo "FAIL: missing ExtensionSettings in ${policy_file}" >&2
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

  echo "PASS: basic policy checks passed (JSON parser unavailable for deep validation)."
}

if [[ $# -eq 0 ]]; then
  :
fi

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

if [[ "${install_url}" != https://* && "${install_url}" != file://* ]]; then
  echo "--install-url must start with https:// or file://" >&2
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

step 2 "Detecting Firefox policy location"
policy_file="$(resolve_policy_file "${os_name}")"
policy_dir="$(dirname "${policy_file}")"

echo "Policy file target: ${policy_file}"
echo "Add-on ID: ${addon_id}"
echo "Install URL: ${install_url}"

step 3 "Preparing Contra policy payload"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

target_policy_json="${work_dir}/contra-policy-target.json"
render_target_policy_json "${target_policy_json}"

final_policy_json="${work_dir}/contra-policy-final.json"

step 4 "Resolving existing policies.json conflicts"
if [[ -f "${policy_file}" ]]; then
  backup_dir="${policy_dir}/contra-policy-backups"
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  backup_path="${backup_dir}/policies-${timestamp}.json"

  install -d -m 0755 "${backup_dir}"
  cp "${policy_file}" "${backup_path}"
  chmod 0644 "${backup_path}"
  echo "Backup created: ${backup_path}"

  if [[ "${on_conflict_explicit}" == false && "${yes_mode}" == false ]]; then
    effective_conflict_mode="$(choose_conflict_mode_interactive)"
  fi

  case "${effective_conflict_mode}" in
    abort)
      echo "Install aborted by user choice after backup."
      exit 0
      ;;
    overwrite)
      cp "${target_policy_json}" "${final_policy_json}"
      ;;
    merge)
      if ! is_perl_jsonpp_available; then
        echo "Merge selected, but Perl JSON::PP is unavailable." >&2
        if [[ "${yes_mode}" == true ]]; then
          echo "Re-run with --on-conflict overwrite or install Perl JSON::PP." >&2
          exit 1
        fi
        effective_conflict_mode="$(choose_conflict_mode_without_merge)"
        if [[ "${effective_conflict_mode}" == "abort" ]]; then
          echo "Install aborted by user choice after backup."
          exit 0
        fi
        cp "${target_policy_json}" "${final_policy_json}"
      else
        merge_policy_json_with_existing "${policy_file}" "${final_policy_json}"
      fi
      ;;
  esac
else
  cp "${target_policy_json}" "${final_policy_json}"
fi

step 5 "Writing policies.json"
install -d -m 0755 "${policy_dir}"
install -m 0644 "${final_policy_json}" "${policy_file}"

step 6 "Verifying installation"
verify_policy_install "${policy_file}"

echo
echo "Hardcore Mode install complete."
echo "Next steps:"
echo "  1. Restart Firefox completely."
echo "  2. Open about:policies and confirm Status is Active."
echo "  3. Confirm ExtensionSettings contains ${addon_id}."
