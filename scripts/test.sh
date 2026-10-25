#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${ROOT_DIR}"
node --check popup.js
node --check background.js
node tests/startup.test.js
node tests/popup.test.js
bash scripts/build-xpi.sh
python3 -m zipfile -t /home/mik/projects/contra/dist/contra.xpi
python3 scripts/test-firefox.py
