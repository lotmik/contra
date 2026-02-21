#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ADDON_ID="contra@ltdmk"
addon_id="${DEFAULT_ADDON_ID}"
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
Usage: scripts/hardcore-uninstall.sh [options]

Remove Contra Firefox enterprise policy lock while preserving unrelated policies.

Options:
  --addon-id ID            Add-on ID to unlock (default: contra@ltdmk)
  --firefox-path PATH      macOS: Firefox .app path (default: auto-detect)
  --yes, -y                Non-interactive mode (currently informational)
  -h, --help               Show help
USAGE
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
    echo "Use scripts/hardcore-uninstall.ps1 on Windows." >&2
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

remove_addon_policy_entry() {
  local input_file="$1"
  local addon_id_value="$2"
  local output_file="$3"

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

print "PASS: Contra policy entry is removed and remaining policies are valid JSON.\n";
' "${policy_file}" "${addon_id}"
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

step 1 "Checking admin permissions and prerequisites"
if [[ "${skip_admin_check}" != "1" && "${EUID}" -ne 0 ]]; then
  echo "Run as admin. Example: sudo scripts/hardcore-uninstall.sh" >&2
  exit 1
fi

os_name="$(uname -s)"

step 2 "Detecting Firefox policy location"
policy_file="$(resolve_policy_file "${os_name}")"
policy_dir="$(dirname "${policy_file}")"

echo "Policy file target: ${policy_file}"
echo "Add-on ID: ${addon_id}"

step 3 "Checking current policy file and creating backup"
if [[ ! -f "${policy_file}" ]]; then
  echo "No policies.json found. Nothing to uninstall for Contra."
  echo
  echo "Hardcore Mode uninstall complete."
  echo "Next steps:"
  echo "  1. Restart Firefox completely."
  echo "  2. Open about:policies and confirm no Contra force-install entry remains."
  exit 0
fi

backup_dir="${policy_dir}/contra-policy-backups"
timestamp="$(date -u +%Y%m%d%H%M%S)"
backup_path="${backup_dir}/policies-${timestamp}.json"

install -d -m 0755 "${backup_dir}"
cp "${policy_file}" "${backup_path}"
chmod 0644 "${backup_path}"
echo "Backup created: ${backup_path}"

step 4 "Removing Contra policy entry"
if ! is_perl_jsonpp_available; then
  echo "Perl JSON::PP is required to safely remove one add-on entry while preserving other policies." >&2
  echo "Install Perl JSON::PP or remove the entry manually from ${policy_file}." >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
updated_policy_json="${work_dir}/policies-updated.json"
remove_result="$(remove_addon_policy_entry "${policy_file}" "${addon_id}" "${updated_policy_json}")"
remove_status="$(printf '%s\n' "${remove_result}" | tail -n 1 | tr -d '[:space:]')"

step 5 "Writing updated policies"
case "${remove_status}" in
  EMPTY)
    rm -f "${policy_file}"
    echo "Removed ${policy_file} because it no longer contains policies."
    ;;
  REMOVED|MISSING)
    install -d -m 0755 "${policy_dir}"
    install -m 0644 "${updated_policy_json}" "${policy_file}"
    if [[ "${remove_status}" == "REMOVED" ]]; then
      echo "Removed Contra entry from ${policy_file}."
    else
      echo "Contra entry was not present; kept other policies unchanged in ${policy_file}."
    fi
    ;;
  *)
    echo "Unexpected removal status: ${remove_status}" >&2
    exit 1
    ;;
esac

step 6 "Verifying uninstall"
verify_policy_uninstall "${policy_file}"

echo
echo "Hardcore Mode uninstall complete."
echo "Next steps:"
echo "  1. Restart Firefox completely."
echo "  2. Open about:policies and confirm Contra is not listed under ExtensionSettings."
