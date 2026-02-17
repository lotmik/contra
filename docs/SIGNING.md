# Signing Fallback (AMO Unlisted)

Use this path if Firefox rejects the local unsigned XPI for policy installation.

## Steps
1. Build package:
   - `scripts/build-xpi.sh`
2. Create/sign in to Firefox Add-ons Developer Hub.
3. Submit `dist/contra.xpi` as **Unlisted**.
4. Download the signed XPI.
5. Replace deployment artifact:
   - Copy signed file to `dist/contra.xpi`.
6. Re-run installer:
   - `scripts/install-firefox-policy.sh --skip-build`

## Notes
- Keep extension ID stable as `contra@local`.
- Any manifest ID change breaks force-install policy mapping.
- Increment `manifest.json` version for each release before building.
