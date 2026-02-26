#!/usr/bin/env bash

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

contra_collect_policy_files() {
  local os_name="$1"
  local firefox_path_override="${2:-}"
  local policy_file_override="${3:-}"
  local normalized_path=""
  local -a candidates=()
  local candidate
  local install_root=""

  if [[ -n "${policy_file_override}" ]]; then
    printf '%s\n' "${policy_file_override}"
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
      if [[ -z "${candidate}" ]]; then
        continue
      fi
      if [[ -f "${candidate}" || -d "$(dirname "${candidate}")" ]]; then
        candidates+=("${candidate}")
        continue
      fi

      case "${candidate}" in
        */distribution/policies.json)
          install_root="${candidate%/distribution/policies.json}"
          if [[ -d "${install_root}" ]]; then
            candidates+=("${candidate}")
          fi
          ;;
        */policies/policies.json)
          install_root="${candidate%/policies/policies.json}"
          if [[ -d "${install_root}" ]]; then
            candidates+=("${candidate}")
          fi
          ;;
      esac
    done < <(contra_emit_known_linux_policy_files)

    if [[ -d "/opt/firefox-developer" ]]; then
      candidates+=("/opt/firefox-developer/distribution/policies.json")
    fi

    if [[ -d "/opt/firefox-developer-edition" ]]; then
      candidates+=("/opt/firefox-developer-edition/distribution/policies.json")
    fi

    if [[ -d "/opt/firefox-nightly" ]]; then
      candidates+=("/opt/firefox-nightly/distribution/policies.json")
    fi

    if [[ -d "/opt/firefox" ]]; then
      candidates+=("/opt/firefox/distribution/policies.json")
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
      candidates+=('/etc/firefox/policies/policies.json')
    fi

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
        if [[ -n "${candidate}" && -d "${candidate}" ]]; then
          candidates+=("${candidate}/Contents/Resources/distribution/policies.json")
        fi
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
  echo "Use scripts/hardcore-install.ps1 or scripts/hardcore-uninstall.ps1 on Windows." >&2
  return 1
}
