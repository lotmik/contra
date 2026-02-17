#!/usr/bin/env bash
set -euo pipefail

TARGET_XPI="/opt/contra/contra.xpi"
POLICY_FILE="/etc/firefox/policies/policies.json"
EXPECTED_INSTALL_URL="file:///opt/contra/contra.xpi"
HAS_RG=false

failures=0

if command -v rg >/dev/null 2>&1; then
  HAS_RG=true
fi

check_exists() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    echo "OK: ${path} exists"
  else
    echo "FAIL: ${path} does not exist"
    failures=$((failures + 1))
  fi
}

check_owner_group() {
  local path="$1"
  local owner_group
  owner_group="$(stat -c '%U:%G' "${path}")"
  if [[ "${owner_group}" == "root:root" ]]; then
    echo "OK: ${path} owned by root:root"
  else
    echo "FAIL: ${path} owner/group is ${owner_group}, expected root:root"
    failures=$((failures + 1))
  fi
}

check_mode() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(stat -c '%a' "${path}")"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "OK: ${path} mode ${actual}"
  else
    echo "FAIL: ${path} mode ${actual}, expected ${expected}"
    failures=$((failures + 1))
  fi
}

check_file_contains() {
  local path="$1"
  local token="$2"
  if [[ "${HAS_RG}" == true ]] && rg -Fq "${token}" "${path}"; then
    echo "OK: ${path} contains ${token}"
  elif [[ "${HAS_RG}" == false ]] && grep -Fq "${token}" "${path}"; then
    echo "OK: ${path} contains ${token}"
  else
    echo "FAIL: ${path} is missing ${token}"
    failures=$((failures + 1))
  fi
}

check_file_not_contains() {
  local path="$1"
  local token="$2"
  if [[ "${HAS_RG}" == true ]] && rg -Fq "${token}" "${path}"; then
    echo "FAIL: ${path} contains forbidden token ${token}"
    failures=$((failures + 1))
  elif [[ "${HAS_RG}" == false ]] && grep -Fq "${token}" "${path}"; then
    echo "FAIL: ${path} contains forbidden token ${token}"
    failures=$((failures + 1))
  else
    echo "OK: ${path} does not contain ${token}"
  fi
}

check_not_user_writable() {
  local path="$1"
  if [[ -w "${path}" ]]; then
    echo "FAIL: current user can write ${path}"
    failures=$((failures + 1))
  else
    echo "OK: current user cannot write ${path}"
  fi
}

check_exists "${TARGET_XPI}"
check_exists "${POLICY_FILE}"

if [[ -e "${TARGET_XPI}" ]]; then
  check_owner_group "${TARGET_XPI}"
  check_mode "${TARGET_XPI}" "444"
  check_not_user_writable "${TARGET_XPI}"
fi

if [[ -e "${POLICY_FILE}" ]]; then
  check_owner_group "${POLICY_FILE}"
  check_mode "${POLICY_FILE}" "644"
  check_not_user_writable "${POLICY_FILE}"
  check_file_contains "${POLICY_FILE}" "\"contra@local\""
  check_file_contains "${POLICY_FILE}" "\"installation_mode\": \"force_installed\""
  check_file_contains "${POLICY_FILE}" "\"install_url\": \"${EXPECTED_INSTALL_URL}\""
  check_file_contains "${POLICY_FILE}" "\"BlockAboutAddons\": true"
  check_file_contains "${POLICY_FILE}" "\"BlockAboutConfig\": true"
  check_file_contains "${POLICY_FILE}" "\"DisableSafeMode\": true"
  check_file_not_contains "${POLICY_FILE}" "\"DisableDeveloperTools\": true"
fi

if [[ "${failures}" -gt 0 ]]; then
  echo
  echo "Verification failed with ${failures} issue(s)."
  echo "Also verify runtime policy status in Firefox: about:policies"
  exit 1
fi

echo
echo "Verification passed."
echo "Still verify Firefox runtime policy status in about:policies."
