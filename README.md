# contra. — break out of the dopamine cage

contra. is a lightweight Firefox addon for bulletproof blocking of distractions.
I built the addon for my personal needs, and it is the only one on the market that really makes itself impossible to bypass, shifting the priority from internet distractions to longer and better [deep work](https://calnewport.com/deep-work-rules-for-focused-success-in-a-distracted-world/) sessions.
## Features
- Blocklist and whitelist
- Phrase mode: allows you to set a phrase and only unblocks if you type it in (you can see the phrase, it is not like a secret password). The phrase has to be something profound, ideally an oath (the default one is a good example), so that when you type it, you make a conscious decision to leave your flow state.
- Timer mode: allows you to set a duration and a "pause phrase" (the same principle as above). When blocked, if time is not up, you cannot stop it, but you can pause by typing in the phrase by 2 minutes.
## Install
The addon has two usecases: you can use it as a normal extention you can always remove OR you can stop yourself completely from bypassing it in advance by using a custom Firefox Entreprise Policy. 

It's not necessary to install the addon from the marketplace because the script below already downloads the latest version for you (but you can still do that). 
<details>
<summary>What the script does</summary>
- policies.DisableSafeMode: true  
    Prevents starting Firefox in Safe/Troubleshoot Mode, which normally disables extensions temporarily, closing a common bypass route.  
    
- policies.BlockAboutSupport: true  
    Blocks about:support, a diagnostics page that can expose troubleshooting actions and profile/runtime details. 
    
- policies.BlockAboutProfiles: true  
    Blocks about:profiles, where users can create/switch Firefox profiles.  
    This prevents jumping to a fresh profile that has no extension policy/history.  
    
- policies.Preferences["extensions.installDistroAddons"] = { Value: true, Status: "locked" }  
    Locks Firefox preference distribution-managed add-ons, keeping contra. always force-installed.
    
- policies.ExtensionSettings[<addon_id>].installation_mode = "force_installed"  
    Prevents removal/disabling of contra.
    
- policies.ExtensionSettings[<addon_id>].install_url = "https://addons.mozilla.org/firefox/downloads/latest/contra-blocker/latest.xpi"  
    This is the part that auto-downloads the latest contra. release.
    
- policies.ExtensionSettings[<addon_id>].private_browsing = true  
    Enables contra. in private windows by default.  
    
- policies.3rdparty.Extensions[<addon_id>].forceAdultBlock = true (optional)  
    Sends a managed config flag directly to the blocker extension to force adult-content blocking behavior.  
    For a blocker, this can lock a sensitive filter category on regardless of UI toggles.  
    Why needed: protects high-risk categories from being disabled when self-control is weakest.
    If adult mode is enabled during config, this line checks if a site you are about to open is in [this](https://github.com/Bon-Appetit/porn-domains) or [this](https://github.com/4skinSkywalker/Anti-Porn-HOSTS-File) list of adult websites. If yes, contra. closes the tab before the website even loads.
</details>

**IMPORTANT:** you have to run the policy installation script as admin (sudo). Normally, if you see something similar on the internet, you **always** have to be highly sceptical. In case of contra., a custom enterprise policy is the only way to make the extention impossible to bypass. That's why I tried to provide the script with comments, and if you are not a technical person, you can check the file yourself on [virustotal.com](https://virustotal.com) or paste the script content to an LLM and ask it to check the safety. **NEVER trust anybody who wants you to run anything as admin.**

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/install-policy.sh | sudo bash
```
### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/lotmik/contra/main/scripts/uninstall-policy.sh | sudo bash
```

## Troubleshooting

If Firefox path detection fails:
- Pass `--firefox-path` explicitly.

If merge mode fails due missing Perl JSON::PP:
- Re-run with `--on-conflict overwrite`, or install Perl JSON::PP.