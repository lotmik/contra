# Contra Deployment Notes (Maintainers)

This document is for maintainers releasing Contra to AMO and maintaining policy scripts.

End-user instructions are in `README.md`.

## Active user-facing scripts

- `scripts/install-policy.sh`
- `scripts/uninstall-policy.sh`

These are self-sufficient admin scripts for Linux/macOS.

## Archived maintainer/helper scripts

Legacy and maintainer tooling lives in `scripts/archive/`, including:
- `scripts/archive/linux-mac/build-xpi.sh`
- `scripts/archive/linux-mac/verify-amo-readiness.sh`
- `scripts/archive/linux-mac/generate-adult-domains.sh`
- historical hardcore/verify scripts and Windows scripts

## Release checklist (AMO-first)

1. Update `manifest.json` version.
2. Run AMO readiness checks:
   - `scripts/archive/linux-mac/verify-amo-readiness.sh`
3. Build package:
   - `scripts/archive/linux-mac/build-xpi.sh`
4. Upload `dist/contra.xpi` to AMO listing.
5. Verify live AMO listing installs correctly.

## Local checks

```bash
bash -n scripts/install-policy.sh
bash -n scripts/uninstall-policy.sh
```

## Manual smoke flow

1. Install Contra from AMO.
2. Run `sudo bash scripts/install-policy.sh`.
3. Restart Firefox.
4. Confirm `about:policies` is active and Contra is force-installed.
5. Run `sudo bash scripts/uninstall-policy.sh`.
6. Restart Firefox and confirm Contra policy entry is removed.
