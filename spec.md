# Spec: Firefox Policy Lock Deployment for `contra`

## Goal
Enforce non-removable extension behavior for non-sudo users in Firefox by using enterprise policies, while keeping extension-side anti-tamper logic as a defense-in-depth layer.

## Scope
- Add operational tooling to build an XPI package.
- Add operational tooling to install and verify Firefox root-owned policies.
- Add policy template for force-installing `contra@local`.
- Add popup status for managed lock visibility.
- Keep anti-tamper blocking of extension-management pages active.

## Out of Scope
- Defending against users with sudo/root access.
- Supporting Flatpak/Snap Firefox policy paths in this iteration.

## Implementation
1. `scripts/build-xpi.sh`
   - Deterministically package required extension files into `dist/contra.xpi`.
2. `deploy/firefox/policies.json`
   - Template with strict hardening and a placeholder install URL.
3. `scripts/install-firefox-policy.sh`
   - Build package, install root-owned XPI to `/opt/contra/contra.xpi`, write `/etc/firefox/policies/policies.json`, keep rollback backup in `/opt/contra/releases/`.
4. `scripts/verify-firefox-policy.sh`
   - Validate required files, ownership/permissions, and policy content expectations.
5. `scripts/uninstall-firefox-policy.sh`
   - Remove policy lock and revert managed XPI using latest backup when available.
6. Popup status
   - Add managed-lock badge and guidance text backed by `browser.management.getSelf()` checks in background worker.

## Verification
- `node --check background.js`
- `node --check popup.js`
- `bash -n scripts/build-xpi.sh`
- `bash -n scripts/install-firefox-policy.sh`
- `bash -n scripts/verify-firefox-policy.sh`
- `scripts/build-xpi.sh` successful
- `scripts/verify-firefox-policy.sh` run (expected warnings/failures before sudo install are acceptable in dev state)
