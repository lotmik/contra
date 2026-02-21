# Contra Deployment Notes (Maintainers)

This document is for maintainers releasing Contra to AMO and maintaining Hardcore Mode scripts.

End-user setup instructions are in the repository `README.md`.

## Release checklist (AMO-first)
1. Update `manifest.json` version.
2. Run AMO readiness checks:
   - `scripts/verify-amo-readiness.sh`
3. Build package:
   - `scripts/build-xpi.sh`
4. Upload `dist/contra.xpi` to AMO listing.
5. Verify live AMO listing installs correctly.

## Hardcore script entrypoints
Primary scripts:
- `scripts/hardcore-install.sh` (Linux + macOS)
- `scripts/hardcore-uninstall.sh` (Linux + macOS)
- `scripts/hardcore-install.ps1` (Windows)
- `scripts/hardcore-uninstall.ps1` (Windows)

Compatibility wrappers (legacy names):
- `scripts/install-firefox-policy.sh` -> forwards to `hardcore-install.sh`
- `scripts/uninstall-firefox-policy.sh` -> forwards to `hardcore-uninstall.sh`

## Hardcore policy scope
Hardcore Mode sets Firefox policy for:
- `policies.ExtensionSettings[contra@ltdmk]`
- `installation_mode: force_installed`
- `private_browsing: true`

No extra enterprise lock policies are applied beyond Contra's `ExtensionSettings` entry.

Compatibility note: `private_browsing` in `ExtensionSettings` requires Firefox `136+` (or ESR `128.8+`).

## Local maintainer checks
```bash
bash -n scripts/hardcore-install.sh
bash -n scripts/hardcore-uninstall.sh
bash -n scripts/install-firefox-policy.sh
bash -n scripts/uninstall-firefox-policy.sh
bash -n scripts/verify-firefox-policy.sh
```

Windows script syntax check (when PowerShell is available):
```powershell
powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('scripts/hardcore-install.ps1',[ref]$null,[ref]$null) | Out-Null"
powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('scripts/hardcore-uninstall.ps1',[ref]$null,[ref]$null) | Out-Null"
```

## Manual smoke flow
1. Install Contra from AMO.
2. Run Hardcore install script as admin.
3. Restart Firefox.
4. Confirm `about:policies` is Active and shows `contra@ltdmk` force-installed with `private_browsing: true`.
5. Run uninstall script as admin.
6. Restart Firefox and confirm Contra policy entry is removed.
