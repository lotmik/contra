#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
OUTPUT_XPI="${DIST_DIR}/contra.xpi"
FIXED_TIMESTAMP="202001010000.00"

FILES=(
  "manifest.json"
  "background.js"
  "popup.html"
  "popup.css"
  "popup.js"
  "data/adult-domains.txt"
  "icons/icon-16.png"
  "icons/icon-32.png"
  "icons/icon-48.png"
  "icons/icon-64.png"
  "icons/icon-96.png"
  "icons/icon-128.png"
)

for relative_path in "${FILES[@]}"; do
  if [[ ! -f "${ROOT_DIR}/${relative_path}" ]]; then
    echo "Missing required file: ${relative_path}" >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${DIST_DIR}"
rm -f "${OUTPUT_XPI}"

for relative_path in "${FILES[@]}"; do
  mkdir -p "${TMP_DIR}/$(dirname "${relative_path}")"
  cp "${ROOT_DIR}/${relative_path}" "${TMP_DIR}/${relative_path}"
  touch -t "${FIXED_TIMESTAMP}" "${TMP_DIR}/${relative_path}"
done

(
  cd "${TMP_DIR}"
  if command -v zip >/dev/null 2>&1; then
    zip -X -q "${OUTPUT_XPI}" "${FILES[@]}"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "${OUTPUT_XPI}" "${FILES[@]}" <<'PY'
import sys
import zipfile

output_xpi = sys.argv[1]
files = sys.argv[2:]

with zipfile.ZipFile(output_xpi, "w", zipfile.ZIP_DEFLATED) as archive:
    for relative_path in files:
        archive.write(relative_path, relative_path)
PY
  else
    echo "Missing required dependency: install zip or python3" >&2
    exit 1
  fi
)

echo "Built ${OUTPUT_XPI}"
