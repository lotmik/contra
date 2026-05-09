<h1 align="center">
<sub>
<img src="https://github.com/lotmik/contra/blob/356a6754a29a0ab4cce7150f01bdd47e9b4d1b57/icons/icon-source.svg" height="38" width="38">
</sub>
contra.
<a href="https://addons.mozilla.org/firefox/addon/contra-blocker/"><img alt="Firefox Add-ons" src="https://img.shields.io/badge/Firefox-141e24.svg?logo=firefox-browser"></a>
<a href="https://en.wikipedia.org/wiki/Linux"><img alt="Linux" src="https://img.shields.io/badge/Linux-FCC624?style=flat&logo=linux&logoColor=black"></a>
</h1>

**contra.** is a lightweight Firefox addon for bulletproof blocking of distractions.

I built this addon for my personal needs because I could not find such a hardcore blocker like Cold Turkey (amazing product btw), but for Linux and for free. I also noticed that 99% of my distractions live in the browser, so controlling Firefox became essential for better and longer [deep work](https://calnewport.com/deep-work-rules-for-focused-success-in-a-distracted-world/) sessions.
## Features
- 📜 **Blocklist** and **whitelist**
- ✍️ **Phrase mode**: allows you to set a phrase and only unblocks if you copy it letter by letter. After typing the phrase, you can either stop blocking or take a 2 minute break. The phrase has to be something profound, ideally an oath, so that when you type it, you make a conscious decision to leave the flow state.
- ⏲️ **Timer mode**: allows you to set a duration and a "pause phrase" (the same principle as above). When blocked, if time is not up, you cannot stop it, but you can pause by typing in the phrase by 2 minutes.
- 🔞 **Adult mode**: blocks all explicit websites from a constantly updated list ([Anti-Porn-HOSTS-File](https://github.com/4skinSkywalker/Anti-Porn-HOSTS-File)). Works independently from other modes.
## Install
Although you can use the addon separately, it is recommended to cut all bypass methods in advance by getting a custom Firefox Entreprise Policy. It basically enforces some rules for Firefox like force install of the addon, which you cannot change easily.

I created a script that automatically installs everything for you, but you can also do it by hand.

<details>
<summary>What the script does</summary>

- `policies.DisableSafeMode: true`  
    Prevents starting Firefox in Safe/Troubleshoot Mode, which normally disables extensions temporarily, closing a common bypass route.  
    
- `policies.BlockAboutSupport: true`  
    Blocks about:support, a diagnostics page that can expose troubleshooting actions and profile/runtime details. 
    
- `policies.BlockAboutProfiles: true`  
    Blocks about:profiles, where users can create/switch Firefox profiles.  
    This prevents jumping to a fresh profile that has no extension policy/history.  
    
- `policies.Preferences["extensions.installDistroAddons"] = { Value: true, Status: "locked" }`  
    Locks Firefox preference distribution-managed add-ons, keeping contra. always force-installed.
    
- `policies.ExtensionSettings[<addon_id>].installation_mode = "force_installed"`  
    Prevents removal/disabling of contra.
    
- `policies.ExtensionSettings[<addon_id>].install_url = "https://addons.mozilla.org/firefox/downloads/latest/contra-blocker/latest.xpi"`  
    This is the part that auto-downloads the latest contra. release.

- `policies.ExtensionUpdate = true`
    Keeps Firefox extension auto-updates enabled under enterprise policy.
    
- `policies.ExtensionSettings[<addon_id>].private_browsing = true`  
    Enables contra. in private windows by default.  
    
- `policies.3rdparty.Extensions[<addon_id>].forceAdultBlock = true` (optional)
    This enables the adult mode. If it is enabled during config, the addon checks if a site you are about to open is in the [Anti-Porn-HOSTS-File list](https://github.com/4skinSkywalker/Anti-Porn-HOSTS-File). If yes, contra. closes the tab before the website even loads.
</details>

⚠️ **IMPORTANT:** you have to run the policy installation script as admin/sudo. In case of contra., a custom policy is the only way to make the addon impossible to bypass. I provided the script with comments, and if you are not a technical person, you can check the file yourself on [VirusTotal](https://virustotal.com) or paste the script content to an LLM and ask it to verify the safety.
### Policy toggle
Run this script as admin. It installs the policy when Contra is not installed, and uninstalls it when Contra is already installed. After installing, reopen all Firefox windows, then go to `about:policies` and confirm the installation.
```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/policy.sh | sudo bash
```
Short version:
```bash
curl -fsSL https://tinyurl.com/contra-policy | sudo bash
```
Use `scripts/policy.sh install` or `scripts/policy.sh uninstall` when you do not want automatic toggle behavior. The policy script is self-contained; it does not fetch archived install/uninstall helper scripts.

For explicit actions from the direct URL:
```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/policy.sh | sudo bash -s -- install
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/policy.sh | sudo bash -s -- uninstall
```

From a cloned repo:
```bash
sudo bash scripts/policy.sh install
sudo bash scripts/policy.sh uninstall
```


## Troubleshooting

If Firefox path detection fails:
- Find the Firefox binary/app path, then pass it with `--firefox-path`.
- Linux (binary path):
  ```bash
  which firefox
  readlink -f "$(which firefox)"
  ```
- Linux common install roots:
  ```bash
  ls -d /usr/lib/firefox* /usr/lib64/firefox* /opt/firefox* 2>/dev/null
  ```
- macOS (app bundle path):
  ```bash
  ls -d /Applications/Firefox*.app "$HOME/Applications/Firefox*.app" 2>/dev/null
  ```
- Example usage:
  ```bash
  sudo bash scripts/policy.sh --firefox-path /usr/lib/firefox
  sudo bash scripts/policy.sh --firefox-path /Applications/Firefox.app
  ```

If the policy script complains about a missing JSON editor:
- First verify what is missing:
  ```bash
  python3 --version
  ```
- The current policy script does not depend on Perl `JSON::PP`. It uses `python3` only when it needs to safely merge with or edit an existing `policies.json`.
- During uninstall, if `python3` is missing, the script prompts you to install Python 3 and continue, remove whole backed-up policy files as an emergency fallback, or abort.
- Install Python 3 if you want safe merge/uninstall support:
  - Debian/Ubuntu:
    ```bash
    sudo apt update && sudo apt install -y python3
    ```
  - Fedora/RHEL/CentOS:
    ```bash
    sudo dnf install -y python3
    ```
  - Arch:
    ```bash
    sudo pacman -S --needed python
    ```
  - macOS (Homebrew):
    ```bash
    brew install python
    ```
- Retry merge mode:
  ```bash
  sudo bash scripts/policy.sh install --on-conflict merge
  ```
- If you want to bypass merge requirements, use overwrite mode:
  ```bash
  sudo bash scripts/policy.sh install --on-conflict overwrite
  ```
- If you want a parser-free emergency uninstall and the Firefox policy file contains only Contra-managed entries, back up and remove the whole `policies.json` file instead of editing it in place.

If policy did not apply after running the script:
- Fully quit Firefox and start it again.
- Open `about:policies` and check that Contra policies are shown as active.
- Re-run with an explicit path:
  ```bash
  sudo bash scripts/policy.sh --firefox-path /path/to/firefox-or-app
  ```
