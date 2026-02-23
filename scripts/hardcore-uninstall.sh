#!/usr/bin/env bash
set -euo pipefail

# TEMP local ID. If publishing cleanup is requested, switch back to "contra@ltdmk".
DEFAULT_ADDON_ID="contra@local"
addon_id="${DEFAULT_ADDON_ID}"
yes_mode=false
firefox_path=""
policy_file_override="${CONTRA_POLICY_FILE_OVERRIDE:-}"
skip_admin_check="${CONTRA_SKIP_ADMIN_CHECK:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/firefox-policy-paths.sh
source "${SCRIPT_DIR}/lib/firefox-policy-paths.sh"

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
  --addon-id ID            Add-on ID to unlock (default: contra@local)
  --firefox-path PATH      Optional Firefox app/bin/install path to include (default: auto-detect)
  --yes, -y                Non-interactive mode (currently informational)
  -h, --help               Show help
USAGE
}

is_perl_jsonpp_available() {
  command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 >/dev/null 2>&1
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

if (ref($data->{policies}) eq "HASH" && exists $data->{policies}->{DisableSafeMode}) {
  delete $data->{policies}->{DisableSafeMode};
  $removed = 1;
  if (!keys %{ $data->{policies} }) {
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

if (ref($data->{policies}) eq "HASH" && exists $data->{policies}->{DisableSafeMode}) {
  die "FAIL: DisableSafeMode still exists in policies\n";
}

print "PASS: Contra policy entry is removed and remaining policies are valid JSON.\n";
' "${policy_file}" "${addon_id}"
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
my $settings = (ref($policies) eq "HASH") ? $policies->{ExtensionSettings} : undef;
my $has_extension = (ref($settings) eq "HASH" && ref($settings->{$addon_id}) eq "HASH") ? 1 : 0;
my $extensions = (ref($policies) eq "HASH" && ref($policies->{"3rdparty"}) eq "HASH") ? $policies->{"3rdparty"}->{Extensions} : undef;
my $managed = (ref($extensions) eq "HASH") ? $extensions->{$addon_id} : undef;
my $has_force_adult = (ref($managed) eq "HASH" && ($managed->{forceAdultBlock} // 0)) ? 1 : 0;

print "FILE_EXISTS=1\n";
print "POLICY_KEYS=" . (@policy_keys ? join(",", @policy_keys) : "<none>") . "\n";
print "HAS_DISABLE_SAFE_MODE=$has_disable\n";
print "HAS_EXTENSION_ENTRY=$has_extension\n";
print "HAS_FORCE_ADULT=$has_force_adult\n";
' "${policy_file}" "${addon_id_value}" > "${output_file}"
}

state_value() {
  local state_file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1==key {print substr($0, index($0, "=") + 1); exit}' "${state_file}"
}

append_csv_item() {
  local var_name="$1"
  local item="$2"
  if [[ -z "${!var_name:-}" ]]; then
    printf -v "${var_name}" '%s' "${item}"
  else
    printf -v "${var_name}" '%s, %s' "${!var_name}" "${item}"
  fi
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

step 3 "Preparing uninstall workspace"
if ! is_perl_jsonpp_available; then
  echo "Perl JSON::PP is required to safely remove one add-on entry while preserving other policies." >&2
  echo "Install Perl JSON::PP or remove entries manually from the target policies.json files." >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
policy_index=0
failed_targets=0
updated_targets=0
removed_all_targets=0
missing_targets=0

step 4 "Applying uninstall updates"
for policy_file in "${policy_files[@]}"; do
  policy_index=$((policy_index + 1))
  policy_dir="$(dirname "${policy_file}")"
  backup_path=""
  before_state_file="${work_dir}/state-before-${policy_index}.txt"
  after_state_file="${work_dir}/state-after-${policy_index}.txt"
  updated_policy_json="${work_dir}/policies-updated-${policy_index}.json"
  remove_error_file="${work_dir}/remove-error-${policy_index}.log"
  removed_list=""
  remaining_targeted_list=""

  echo "Target: ${policy_file}"

  if [[ ! -f "${policy_file}" ]]; then
    echo "  No policies.json present; nothing to uninstall."
    missing_targets=$((missing_targets + 1))
    continue
  fi

  if ! collect_policy_state "${policy_file}" "${addon_id}" "${before_state_file}" 2>"${remove_error_file}"; then
    echo "  ERROR: cannot parse existing policy JSON; skipped target: $(tr '\n' ' ' < "${remove_error_file}")"
    failed_targets=$((failed_targets + 1))
    continue
  fi

  backup_dir="${policy_dir}/contra-policy-backups"
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  backup_path="${backup_dir}/policies-${timestamp}-${policy_index}.json"

  if ! install -d -m 0755 "${backup_dir}"; then
    echo "  ERROR: could not create backup directory ${backup_dir}"
    failed_targets=$((failed_targets + 1))
    continue
  fi
  if ! cp "${policy_file}" "${backup_path}"; then
    echo "  ERROR: could not create backup at ${backup_path}"
    failed_targets=$((failed_targets + 1))
    continue
  fi
  chmod 0644 "${backup_path}"
  echo "  Backup: ${backup_path}"

  if ! remove_result="$(remove_addon_policy_entry "${policy_file}" "${addon_id}" "${updated_policy_json}" 2>"${remove_error_file}")"; then
    echo "  ERROR: failed to remove Contra policy entry: $(tr '\n' ' ' < "${remove_error_file}")"
    failed_targets=$((failed_targets + 1))
    continue
  fi
  remove_status="$(printf '%s\n' "${remove_result}" | tail -n 1 | tr -d '[:space:]')"

  case "${remove_status}" in
    EMPTY)
      if ! rm -f "${policy_file}"; then
        echo "  ERROR: could not remove ${policy_file}"
        failed_targets=$((failed_targets + 1))
        continue
      fi
      removed_all_targets=$((removed_all_targets + 1))
      ;;
    REMOVED|MISSING)
      if ! install -d -m 0755 "${policy_dir}"; then
        echo "  ERROR: could not create policy directory ${policy_dir}"
        failed_targets=$((failed_targets + 1))
        continue
      fi
      if ! install -m 0644 "${updated_policy_json}" "${policy_file}"; then
        echo "  ERROR: could not write ${policy_file}"
        failed_targets=$((failed_targets + 1))
        continue
      fi
      updated_targets=$((updated_targets + 1))
      ;;
    *)
      echo "  ERROR: unexpected removal status '${remove_status}'"
      failed_targets=$((failed_targets + 1))
      continue
      ;;
  esac

  if ! verify_policy_uninstall "${policy_file}" >/dev/null 2>&1; then
    echo "  ERROR: post-uninstall verification failed for ${policy_file}"
    failed_targets=$((failed_targets + 1))
    continue
  fi

  if ! collect_policy_state "${policy_file}" "${addon_id}" "${after_state_file}" 2>"${remove_error_file}"; then
    echo "  ERROR: cannot read final policy state: $(tr '\n' ' ' < "${remove_error_file}")"
    failed_targets=$((failed_targets + 1))
    continue
  fi

  before_disable="$(state_value "${before_state_file}" "HAS_DISABLE_SAFE_MODE")"
  before_extension="$(state_value "${before_state_file}" "HAS_EXTENSION_ENTRY")"
  before_force_adult="$(state_value "${before_state_file}" "HAS_FORCE_ADULT")"
  after_disable="$(state_value "${after_state_file}" "HAS_DISABLE_SAFE_MODE")"
  after_extension="$(state_value "${after_state_file}" "HAS_EXTENSION_ENTRY")"
  after_force_adult="$(state_value "${after_state_file}" "HAS_FORCE_ADULT")"
  policy_keys_left="$(state_value "${after_state_file}" "POLICY_KEYS")"

  if [[ "${before_disable}" == "1" && "${after_disable}" == "0" ]]; then
    append_csv_item removed_list "DisableSafeMode"
  fi
  if [[ "${before_extension}" == "1" && "${after_extension}" == "0" ]]; then
    append_csv_item removed_list "ExtensionSettings[${addon_id}]"
  fi
  if [[ "${before_force_adult}" == "1" && "${after_force_adult}" == "0" ]]; then
    append_csv_item removed_list "3rdparty.Extensions[${addon_id}].forceAdultBlock"
  fi

  if [[ "${after_disable}" == "1" ]]; then
    append_csv_item remaining_targeted_list "DisableSafeMode"
  fi
  if [[ "${after_extension}" == "1" ]]; then
    append_csv_item remaining_targeted_list "ExtensionSettings[${addon_id}]"
  fi
  if [[ "${after_force_adult}" == "1" ]]; then
    append_csv_item remaining_targeted_list "3rdparty.Extensions[${addon_id}].forceAdultBlock"
  fi

  if [[ -z "${removed_list}" ]]; then
    removed_list="none"
  fi
  if [[ -z "${remaining_targeted_list}" ]]; then
    remaining_targeted_list="none"
  fi

  echo "  Uninstalled policies: ${removed_list}"
  echo "  Targeted policies left: ${remaining_targeted_list}"
  echo "  Policies left in file: ${policy_keys_left}"
done

step 5 "Uninstall summary"
echo "Targets without policies.json: ${missing_targets}"
echo "Targets updated: ${updated_targets}"
echo "Targets removed entirely: ${removed_all_targets}"
echo "Targets failed: ${failed_targets}"

step 6 "Result"
if [[ "${failed_targets}" -gt 0 ]]; then
  echo "Hardcore Mode uninstall finished with errors."
  echo "Fix failed targets and run uninstall again."
  exit 1
fi

echo "Hardcore Mode uninstall complete."
echo "Next steps:"
echo "  1. Restart Firefox completely."
echo "  2. Open about:policies and confirm Contra is not listed under ExtensionSettings."
echo "  3. Confirm DisableSafeMode is not set by Contra policies."
