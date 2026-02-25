#!/usr/bin/env bash

contra_default_local_xpi_path() {
  printf '%s' '/home/mik/code/contra/dist/contra@local.xpi'
}

contra_emit_profile_roots_from_homes() {
  local home_dir
  for home_dir in /home/* /root; do
    if [[ -d "${home_dir}/.mozilla/firefox" ]]; then
      printf '%s\n' "${home_dir}/.mozilla/firefox"
    fi
  done
}

contra_emit_profile_roots() {
  local sudo_home=""
  local sudo_user_home=""
  local custom_roots="${CONTRA_FIREFOX_PROFILE_ROOTS:-}"
  local item

  if [[ -n "${custom_roots}" ]]; then
    IFS=':' read -r -a _custom_root_items <<< "${custom_roots}"
    for item in "${_custom_root_items[@]}"; do
      if [[ -n "${item}" ]]; then
        printf '%s\n' "${item}"
      fi
    done
  fi

  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | awk -F: 'NR==1 {print $6}')"
    if [[ -n "${sudo_home}" ]]; then
      printf '%s\n' "${sudo_home}/.mozilla/firefox"
    fi
  fi

  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "${HOME}/.mozilla/firefox"
  fi

  sudo_user_home="$(getent passwd "$(id -un)" 2>/dev/null | awk -F: 'NR==1 {print $6}')"
  if [[ -n "${sudo_user_home}" ]]; then
    printf '%s\n' "${sudo_user_home}/.mozilla/firefox"
  fi

  contra_emit_profile_roots_from_homes
}

contra_collect_profile_roots() {
  contra_emit_profile_roots | awk 'NF && !seen[$0]++ && system("[ -d \"" $0 "\" ]") == 0'
}

contra_emit_profiles_from_profiles_ini() {
  local profile_root="$1"
  local ini_file="${profile_root}/profiles.ini"
  local path_value=""
  local resolved=""

  if [[ ! -f "${ini_file}" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    case "${line}" in
      Path=*)
        path_value="${line#Path=}"
        if [[ -z "${path_value}" ]]; then
          continue
        fi
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

contra_emit_profiles_from_root_scan() {
  local profile_root="$1"
  local profile_dir=""
  local base_name=""

  for profile_dir in "${profile_root}"/*; do
    if [[ ! -d "${profile_dir}" ]]; then
      continue
    fi
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

contra_collect_firefox_profiles() {
  local profile_root=""
  while IFS= read -r profile_root; do
    if [[ -z "${profile_root}" || ! -d "${profile_root}" ]]; then
      continue
    fi
    contra_emit_profiles_from_profiles_ini "${profile_root}"
    contra_emit_profiles_from_root_scan "${profile_root}"
  done < <(contra_collect_profile_roots)
}

contra_collect_firefox_profiles_unique() {
  contra_collect_firefox_profiles | awk 'NF && !seen[$0]++ && system("[ -d \"" $0 "\" ]") == 0'
}

contra_profile_extension_path() {
  local profile_dir="$1"
  local addon_id="$2"
  printf '%s/extensions/%s.xpi' "${profile_dir}" "${addon_id}"
}

contra_owner_group_for_path() {
  local target_path="$1"
  stat -c '%u:%g' "${target_path}" 2>/dev/null || true
}

contra_seed_profile_xpi() {
  local profile_dir="$1"
  local source_xpi="$2"
  local addon_id="$3"
  local extension_dir="${profile_dir}/extensions"
  local extension_file=""
  local owner_group=""
  local action="seeded"
  local had_existing=false

  extension_file="$(contra_profile_extension_path "${profile_dir}" "${addon_id}")"

  if [[ ! -d "${profile_dir}" ]]; then
    printf 'failed|%s|profile directory missing\n' "${profile_dir}"
    return 1
  fi

  if [[ ! -f "${source_xpi}" ]]; then
    printf 'failed|%s|source XPI missing: %s\n' "${profile_dir}" "${source_xpi}"
    return 1
  fi

  owner_group="$(contra_owner_group_for_path "${profile_dir}")"

  if [[ -f "${extension_file}" ]]; then
    had_existing=true
    if cmp -s "${source_xpi}" "${extension_file}"; then
      printf 'already up-to-date|%s|%s\n' "${profile_dir}" "${extension_file}"
      return 0
    fi
    action="updated"
  fi

  if ! install -d -m 0755 "${extension_dir}"; then
    printf 'failed|%s|could not create extensions directory: %s\n' "${profile_dir}" "${extension_dir}"
    return 1
  fi

  if [[ -n "${owner_group}" ]]; then
    chown "${owner_group}" "${extension_dir}" >/dev/null 2>&1 || true
  fi

  if ! install -m 0644 "${source_xpi}" "${extension_file}"; then
    printf 'failed|%s|could not write extension file: %s\n' "${profile_dir}" "${extension_file}"
    return 1
  fi

  if [[ -n "${owner_group}" ]]; then
    chown "${owner_group}" "${extension_file}" >/dev/null 2>&1 || true
  fi

  if [[ "${had_existing}" == false ]]; then
    action="seeded"
  fi
  printf '%s|%s|%s\n' "${action}" "${profile_dir}" "${extension_file}"
}

contra_remove_profile_xpi() {
  local profile_dir="$1"
  local addon_id="$2"
  local extension_file=""

  extension_file="$(contra_profile_extension_path "${profile_dir}" "${addon_id}")"

  if [[ ! -d "${profile_dir}" ]]; then
    printf 'failed|%s|profile directory missing\n' "${profile_dir}"
    return 1
  fi

  if [[ ! -e "${extension_file}" ]]; then
    printf 'missing|%s|%s\n' "${profile_dir}" "${extension_file}"
    return 0
  fi

  if ! rm -f "${extension_file}"; then
    printf 'failed|%s|could not remove extension file: %s\n' "${profile_dir}" "${extension_file}"
    return 1
  fi

  printf 'removed|%s|%s\n' "${profile_dir}" "${extension_file}"
}

contra_check_profile_addon_runtime_state() {
  local profile_dir="$1"
  local addon_id="$2"
  local extension_file=""
  local extensions_json=""
  local perl_status=0
  local perl_output=""

  extension_file="$(contra_profile_extension_path "${profile_dir}" "${addon_id}")"
  if [[ ! -f "${extension_file}" ]]; then
    printf 'missing_xpi'
    return 1
  fi
  if [[ ! -r "${extension_file}" ]]; then
    printf 'xpi_not_readable'
    return 1
  fi

  extensions_json="${profile_dir}/extensions.json"
  if [[ ! -f "${extensions_json}" ]]; then
    printf 'ok'
    return 0
  fi

  if ! command -v perl >/dev/null 2>&1; then
    printf 'ok'
    return 0
  fi
  if ! perl -MJSON::PP -e 1 >/dev/null 2>&1; then
    printf 'ok'
    return 0
  fi

  perl_output="$(
    perl -MJSON::PP -e '
use strict;
use warnings;

my ($path, $addon_id) = @ARGV;
open my $fh, "<", $path or do {
  print "extensions_json_unreadable";
  exit 2;
};
local $/;
my $raw = <$fh>;
close $fh;

my $data = eval { JSON::PP::decode_json($raw) };
if ($@ || ref($data) ne "HASH") {
  print "extensions_json_invalid";
  exit 2;
}

my $addons = $data->{addons};
if (ref($addons) ne "ARRAY") {
  print "ok";
  exit 0;
}

for my $entry (@{$addons}) {
  next if ref($entry) ne "HASH";
  next if ($entry->{id} // "") ne $addon_id;

  my $active = $entry->{active} ? 1 : 0;
  my $user_disabled = $entry->{userDisabled} ? 1 : 0;
  my $app_disabled = $entry->{appDisabled} ? 1 : 0;

  if (!$active || $user_disabled || $app_disabled) {
    print "disabled_or_inactive";
    exit 1;
  }

  print "ok";
  exit 0;
}

print "ok";
exit 0;
' "${extensions_json}" "${addon_id}" 2>/dev/null
  )" || perl_status=$?

  if [[ ${perl_status} -eq 1 ]]; then
    printf '%s' "${perl_output:-disabled_or_inactive}"
    return 1
  fi

  if [[ ${perl_status} -ge 2 ]]; then
    printf '%s' "${perl_output:-extensions_json_error}"
    return 1
  fi

  printf '%s' "${perl_output:-ok}"
  return 0
}
