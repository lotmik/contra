<h1 align="center">
<sub>
<img src="https://github.com/lotmik/contra/blob/356a6754a29a0ab4cce7150f01bdd47e9b4d1b57/icons/icon-source.svg" height="38" width="38">
</sub>
contra.
<a rel="noreferrer noopener" href="https://addons.mozilla.org/firefox/addon/contra-blocker/"><img alt="Firefox Add-ons" src="https://img.shields.io/badge/Firefox-141e24.svg?logo=firefox-browser"></a>
<img alt="Firefox Downloads" src="https://img.shields.io/amo/dw/contra%40ltdmk?label=Downloads">
<img alt="Firefox Rating" src="https://img.shields.io/amo/rating/contra%40ltdmk?label=Rating">
<img alt="Linux" src="https://img.shields.io/badge/Linux-FCC624?style=flat&logo=linux&logoColor=black">
</h1>

contra. is a lightweight Firefox addon for bulletproof blocking of distractions.
I built the addon for my personal needs, and it is the only one on the market that really makes itself impossible to bypass, shifting the priority from internet distractions to longer and better [deep work](https://calnewport.com/deep-work-rules-for-focused-success-in-a-distracted-world/) sessions.
## Features
- 📜 **Block**list and **white**list
- ✍️ **Phrase mode**: allows you to set a phrase and only unblocks if you type it in (you can see the phrase, it is not like a secret password). The phrase has to be something profound, ideally an oath (the default one is a good example), so that when you type it, you make a conscious decision to leave your flow state.
- ⏲️ **Timer mode**: allows you to set a duration and a "pause phrase" (the same principle as above). When blocked, if time is not up, you cannot stop it, but you can pause by typing in the phrase by 2 minutes.
- 🔞 **Adult mode**: when enabled, offers a bulletproof blocking of all explicit websites from two constantly updated lists ([this](https://github.com/Bon-Appetit/porn-domains) and [this](https://github.com/4skinSkywalker/Anti-Porn-HOSTS-File)).
## Install
The addon has two usecases: you can use it as a normal extention you can always remove OR you can stop yourself completely from bypassing it in advance by using a custom Firefox Entreprise Policy. Basically, it enforces some rules for firefox which a non-admin user cannot change.

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
    
- `policies.ExtensionSettings[<addon_id>].private_browsing = true`  
    Enables contra. in private windows by default.  
    
- `policies.3rdparty.Extensions[<addon_id>].forceAdultBlock = true` (optional)
    This enables the adult mode. If it is enabled during config, the addon checks if a site you are about to open is in [this](https://github.com/Bon-Appetit/porn-domains) or [this](https://github.com/4skinSkywalker/Anti-Porn-HOSTS-File) list of explicit websites. If yes, contra. closes the tab before the website even loads. (Out of the contra's size of 4,3MB, 99% is used up by these pre-packed lists.)
</details>

⚠️ **IMPORTANT:** you have to run the policy installation script as admin (sudo). Normally, if you see something similar on the internet, you **always** have to be highly sceptical. In case of contra., a custom enterprise policy is the only way to make the extention impossible to bypass. That's why I tried to provide the script with comments, and if you are not a technical person, you can check the file yourself on [VirusTotal](https://virustotal.com) or paste the script content to an LLM and ask it to check the safety. **NEVER trust anybody who wants you to run anything as admin.**

### Policy install
Run this script as admin, then reopen all Firefox windows. After that, go to `about:policies` and confirm the installation.
```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/install-policy.sh | sudo bash
```
### Uninstall
The script is intended to be emergency-only, be really conscious when running it.

```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/uninstall-policy.sh | sudo bash
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
  sudo bash scripts/install-policy.sh --firefox-path /usr/lib/firefox
  sudo bash scripts/install-policy.sh --firefox-path /Applications/Firefox.app
  ```

If merge mode fails due missing Perl JSON::PP:
- First verify what is missing:
  ```bash
  perl -v
  perl -MJSON::PP -e 'print "JSON::PP OK\n"'
  ```
- Install Perl + JSON::PP:
  - Debian/Ubuntu:
    ```bash
    sudo apt update && sudo apt install -y perl
    ```
  - Fedora/RHEL/CentOS:
    ```bash
    sudo dnf install -y perl
    ```
  - Arch:
    ```bash
    sudo pacman -S --needed perl
    ```
  - macOS (Homebrew):
    ```bash
    brew install perl
    ```
- Retry merge mode:
  ```bash
  sudo bash scripts/install-policy.sh --on-conflict merge
  ```
- If you want to bypass merge requirements, use overwrite mode:
  ```bash
  sudo bash scripts/install-policy.sh --on-conflict overwrite
  ```

If policy did not apply after running the script:
- Fully quit Firefox and start it again.
- Open `about:policies` and check that Contra policies are shown as active.
- Re-run with an explicit path:
  ```bash
  sudo bash scripts/install-policy.sh --firefox-path /path/to/firefox-or-app
  ```
