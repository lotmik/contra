# Signing and Distribution Notes (Maintainers)

## Default distribution model

Contra is AMO-first.

- Users install from Firefox Add-ons Marketplace.
- Policy scripts in this repo are for enterprise lock/unlock, not package hosting.

## Manifest constraints

- Keep `browser_specific_settings.gecko.id` stable as `contra@ltdmk` for production.
- Keep `browser_specific_settings.gecko.update_url` unset for AMO distribution.
- Keep data collection declaration aligned with AMO requirements.

## If AMO unlisted signing is needed

1. Build package:
   - `scripts/archive/linux-mac/build-xpi.sh`
2. Submit `dist/contra.xpi` to AMO as **Unlisted**.
3. Download signed XPI from AMO.
4. Host signed XPI on trusted HTTPS storage.
5. Install policy with explicit URL override:
   - `sudo bash scripts/install-policy.sh --install-url "https://example.com/contra.xpi"`

## Why add-on ID stability matters

Firefox enterprise policy mapping uses add-on ID in `ExtensionSettings`.
If the ID changes, policy no longer targets the installed add-on.
