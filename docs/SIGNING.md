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

## AMO Publishing Formalities
- `manifest.json` is AMO-ready by default:
  - `browser_specific_settings.gecko.id` is set and stable.
  - `browser_specific_settings.gecko.update_url` is intentionally omitted.
  - `browser_specific_settings.gecko.data_collection_permissions.required` is set to `["none"]`.
- For AMO-listed or AMO-unlisted distribution, keep `update_url` unset and let AMO manage updates.
- Only add `gecko.update_url` for a self-hosted update channel outside AMO.
