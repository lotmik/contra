# contra. - break out of the dopamine cage

contra. is a lightweight Firefox addon for bulletproof blocking distractions.

Hardcore Mode uses Firefox enterprise policy so the add-on stays force-installed and cannot be disabled/removed through normal browser UI.

## Hardcore Mode setup (Linux/macOS)

### 1) Install Contra from AMO
1. Install Contra from Firefox Add-ons Marketplace.
2. Confirm Contra appears in Firefox add-ons.

### 2) Run one admin script from this repository

Safe flow (download, inspect, run):

```bash
curl -fsSL -o install-policy.sh https://raw.githubusercontent.com/lotmik/contra/main/scripts/install-policy.sh
less install-policy.sh
sudo bash install-policy.sh
```

Convenience flow:

```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/install-policy.sh | sudo bash
```

## Uninstall Hardcore Mode

```bash
curl -fsSL -o uninstall-policy.sh https://raw.githubusercontent.com/lotmik/contra/main/scripts/uninstall-policy.sh
less uninstall-policy.sh
sudo bash uninstall-policy.sh
```

## Important behavior

`install-policy.sh`:
- Creates backups of existing `policies.json` files before edits.
- Enforces:
  - `DisableSafeMode: true`
  - `BlockAboutSupport: true`
  - `BlockAboutProfiles: true`
  - locked `Preferences.extensions.installDistroAddons`
  - force-installed Contra entry in `ExtensionSettings`
- Prompts for forced adult policy (`Y/n`, default yes).
- Seeds profile XPI files by default.
- Sets up runtime guard/rescan services when `systemctl` is available.

`uninstall-policy.sh`:
- Removes Contra-managed policy keys while preserving unrelated policies.
- Removes profile-seeded extension XPI files by default.
- Removes runtime guard/rescan files by default.

Both scripts print:
- each policy file touched
- what changed
- what policies are left
- final summary sections including "Policies removed by this run" and "Policies left after this run"

## Optional flags

Install:

```bash
sudo bash install-policy.sh --on-conflict merge --guard-mode enforce --profile-seed on
```

Use a custom Firefox path:

```bash
sudo bash install-policy.sh --firefox-path "/Applications/Firefox.app"
```

Disable forced adult policy:

```bash
sudo bash install-policy.sh --no-adult
```

Uninstall but keep runtime guard:

```bash
sudo bash uninstall-policy.sh --keep-guard
```

## Troubleshooting

If Firefox path detection fails:
- Pass `--firefox-path` explicitly.

If merge mode fails due missing Perl JSON::PP:
- Re-run with `--on-conflict overwrite`, or install Perl JSON::PP.

## Notes

- This repository currently documents and ships the `.sh` flow only.
- Maintainer helper scripts were moved under `scripts/archive/`.
