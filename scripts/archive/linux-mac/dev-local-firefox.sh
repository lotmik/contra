#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_XPI="${ROOT_DIR}/dist/contra.xpi"
DEFAULT_PROFILE_DIR="${HOME}/.mozilla/firefox/contra-dev-profile"

xpi_path="${DEFAULT_XPI}"
profile_dir="${DEFAULT_PROFILE_DIR}"
browser_bin=""

usage() {
  cat <<'EOF'
Usage: scripts/dev-local-firefox.sh [--xpi PATH] [--profile-dir PATH] [--browser BIN]

Starts a dedicated local-dev Firefox profile with unsigned-addon preference enabled.
Works on Firefox Developer Edition/Nightly. Release Firefox typically ignores this preference.
EOF
}

detect_browser() {
  local candidates=("firefox-developer-edition" "firefox-nightly" "firefox")
  for candidate in "${candidates[@]}"; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return
    fi
  done
  echo ""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xpi)
      xpi_path="$2"
      shift 2
      ;;
    --profile-dir)
      profile_dir="$2"
      shift 2
      ;;
    --browser)
      browser_bin="$2"
      shift 2
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

if [[ -z "${browser_bin}" ]]; then
  browser_bin="$(detect_browser)"
fi

if [[ -z "${browser_bin}" ]]; then
  echo "Could not find Firefox binary." >&2
  echo "Install Firefox Developer Edition/Nightly or pass --browser." >&2
  exit 1
fi

if [[ ! -f "${xpi_path}" ]]; then
  echo "XPI not found at ${xpi_path}" >&2
  echo "Run scripts/build-xpi.sh first." >&2
  exit 1
fi

mkdir -p "${profile_dir}"
cat > "${profile_dir}/user.js" <<EOF
user_pref("xpinstall.signatures.required", false);
user_pref("extensions.autoDisableScopes", 0);
EOF

echo "Browser: ${browser_bin}"
echo "Profile: ${profile_dir}"
echo "XPI: ${xpi_path}"
echo
echo "Install flow (first run for this profile):"
echo "  1. In Firefox, open about:addons."
echo "  2. Click gear icon -> Install Add-on From File..."
echo "  3. Select ${xpi_path}."
echo
echo "Launching..."
"${browser_bin}" -no-remote -profile "${profile_dir}" "about:addons"
