# contra. - break out of the dopamine cage

If you have ever been on the interner before, you know how addictive it can become. You know how corporations fight for your attention only to monetize on it by showing you even more ads. And if you have tried website blockers before, you know how unreliable and easy-to-bypass they normally are.

**contra**. is a lightweight browser extention that helps you regain control over your digital life: deep work sessions become much easier when you don't have access to distractions on your working machine. And with **hardcore mode**, you make it impossible to bypass your own restrictions at all: Firefox enterprise policy keeps the add-on force-installed so you cannot remove it.

## Hardcore mode setup

contra. uses Firefox enterprise policy that keeps the add-on force-installed so you cannot remove it.
<details>
<summary>Firefox</summary>

</details>

### Step 1: Install Contra from Firefox Add-ons Marketplace
1. Install Contra from AMO.
2. Confirm Contra appears in your Firefox toolbar/add-ons list.

### Step 2: Open this GitHub repo and run one admin script
Use the commands for your OS below.

## Linux and macOS

### Safe flow (recommended: download, inspect, run)
```bash
curl -fsSL -o hardcore-install.sh https://raw.githubusercontent.com/lotmik/contra/main/scripts/hardcore-install.sh
less hardcore-install.sh
sudo bash hardcore-install.sh
```

### Convenience flow (faster, less inspectable)
```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/hardcore-install.sh | sudo bash
```

### Optional flags
```bash
sudo bash hardcore-install.sh --addon-id contra@ltdmk --on-conflict merge
```

```bash
sudo bash hardcore-install.sh --adult
```

```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/hardcore-install.sh | sudo bash -s -- --adult
```

## Windows

Open **PowerShell as Administrator**.

### Safe flow (recommended: download, inspect, run)
```powershell
$repo = "https://raw.githubusercontent.com/lotmik/contra/main/scripts"
Invoke-WebRequest "$repo/hardcore-install.ps1" -OutFile ".\hardcore-install.ps1"
Get-Content .\hardcore-install.ps1
.\hardcore-install.ps1
```

### Convenience flow (faster, less inspectable)
```powershell
irm https://raw.githubusercontent.com/lotmik/contra/main/scripts/hardcore-install.ps1 | iex
```

## What Hardcore Mode does
- Writes Firefox enterprise policy `ExtensionSettings` for Contra.
- Sets Contra to `force_installed`.
- Sets `private_browsing: true` so Contra can run in private windows under enterprise policy.
- Optional `--adult` flag sets enterprise managed config `forceAdultBlock: true`:
  - adult blocking is enforced even when the normal block toggle is off
  - the popup adult toggle is hidden and cannot be disabled
- Makes normal Firefox remove/disable flows unavailable for this add-on.
- Backs up existing `policies.json` first.
- Verifies setup at the end and prints PASS/FAIL.

`private_browsing` policy support requires Firefox `136+` (or ESR `128.8+`).

## What Hardcore Mode does not do
- It does not protect against users with full admin/root privileges.
- It does not apply extra enterprise blocks like `about:config` or `about:addons` policy locks.
- It does not support non-standard Firefox packaging paths (for example Flatpak/Snap) in this version.

## Verify after install
1. Fully restart Firefox.
2. Open `about:policies`.
3. Confirm **Status: Active**.
4. Confirm `ExtensionSettings` contains `contra@ltdmk` with `installation_mode: force_installed`.
5. Confirm the same entry includes `private_browsing: true`.

## Uninstall Hardcore Mode

### Linux and macOS
```bash
curl -fsSL -o hardcore-uninstall.sh https://raw.githubusercontent.com/lotmik/contra/main/scripts/hardcore-uninstall.sh
sudo bash hardcore-uninstall.sh
```

### Windows (PowerShell as Administrator)
```powershell
$repo = "https://raw.githubusercontent.com/lotmik/contra/main/scripts"
Invoke-WebRequest "$repo/hardcore-uninstall.ps1" -OutFile ".\hardcore-uninstall.ps1"
.\hardcore-uninstall.ps1
```

## Troubleshooting

### Script says Firefox path was not found
- Linux uses `/etc/firefox/policies/policies.json`.
- macOS: pass a custom path, for example:
```bash
sudo bash hardcore-install.sh --firefox-path "/Applications/Firefox.app"
```
- Windows: pass install path or `firefox.exe` path:
```powershell
.\hardcore-install.ps1 --firefox-path "C:\Program Files\Mozilla Firefox"
```

### Existing policies.json conflict
Installer supports:
- `merge` (default): keeps other policies and adds Contra.
- `overwrite`: replaces file with Contra-only policy.
- `abort`: exits without writing.

Example:
```bash
sudo bash hardcore-install.sh --on-conflict overwrite
```

### I installed from AMO but policy still not active
- Ensure you ran script as admin/root.
- Fully quit and reopen Firefox.
- Re-check `about:policies`.
- Run verification script manually on Linux/macOS:
```bash
bash scripts/verify-firefox-policy.sh
```
- If installed with forced adult mode:
```bash
bash scripts/verify-firefox-policy.sh --adult
```

## Why this README is search-friendly
People usually search for terms like:
- "Firefox unremovable extension"
- "Firefox website blocker cannot disable"
- "force install Firefox add-on enterprise policy"
- "digital detox Firefox extension"

This page is intentionally structured around those use cases so users can find setup quickly and finish in minutes.
