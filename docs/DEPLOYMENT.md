# Firefox Policy Deployment (Linux + sudo)

## Versioning Rule
Before each deployment:
1. Increment `manifest.json` `version`.
2. Rebuild XPI (`scripts/build-xpi.sh`).
3. Install policy/XPI (`scripts/install-firefox-policy.sh`).

## One-Command Install
```bash
scripts/install-firefox-policy.sh
```

This policy setup does **not** disable Developer Tools, so `about:debugging` remains available.
If you installed an older template, run the install command again to rewrite `/etc/firefox/policies/policies.json`.

## Verify
```bash
scripts/verify-firefox-policy.sh
```

Then in Firefox:
1. Restart Firefox completely.
2. Open `about:policies`.
3. Confirm policy status is Active and `ExtensionSettings` includes `contra@local`.

## Update Flow
1. Bump `manifest.json` version.
2. Run `scripts/install-firefox-policy.sh`.
3. Restart Firefox.
4. Run `scripts/verify-firefox-policy.sh`.

## Rollback Flow
1. List backups:
   - `sudo ls -1 /opt/contra/releases`
2. Restore a backup:
   - `sudo cp /opt/contra/releases/contra-YYYYMMDDHHMMSS.xpi /opt/contra/contra.xpi`
   - `sudo chmod 0444 /opt/contra/contra.xpi`
3. Restart Firefox.
4. Re-run verification.

## Emergency Admin Unlock
```bash
sudo rm -f /etc/firefox/policies/policies.json
```

Then restart Firefox.

## One-Command Uninstall/Revert
```bash
scripts/uninstall-firefox-policy.sh
```

Optional flags:
- `--no-restore-backup`: remove policy and skip backup restore.
- `--keep-managed-xpi`: keep `/opt/contra/contra.xpi` in place.
