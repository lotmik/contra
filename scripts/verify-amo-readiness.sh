#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="${ROOT_DIR}/manifest.json"
POPUP_HTML_PATH="${ROOT_DIR}/popup.html"

node - "${MANIFEST_PATH}" <<'NODE'
const fs = require("node:fs");
const manifestPath = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const errors = [];

if (!manifest?.browser_specific_settings?.gecko?.id) {
  errors.push("missing browser_specific_settings.gecko.id");
}

if (manifest?.browser_specific_settings?.gecko?.update_url) {
  errors.push("browser_specific_settings.gecko.update_url must be omitted for AMO distribution");
}

const required = manifest?.browser_specific_settings?.gecko?.data_collection_permissions?.required;
if (!Array.isArray(required) || required.length !== 1 || required[0] !== "none") {
  errors.push("browser_specific_settings.gecko.data_collection_permissions.required must be exactly [\"none\"]");
}

if (errors.length > 0) {
  for (const issue of errors) {
    console.error(`FAIL: ${issue}`);
  }
  process.exit(1);
}

console.log("OK: manifest AMO formalities passed.");
NODE

if rg -n "fonts.googleapis.com|fonts.gstatic.com" "${POPUP_HTML_PATH}" >/dev/null; then
  echo "FAIL: popup.html still references remote Google Fonts."
  exit 1
fi

echo "OK: popup.html has no remote Google Fonts dependency."
echo "AMO readiness checks passed."
