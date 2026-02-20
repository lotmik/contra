$ErrorActionPreference = "Stop"

function Show-Usage {
  @"
Usage: scripts/hardcore-install.ps1 [options]

Install Firefox enterprise policy so Contra cannot be removed/disabled.

Options:
  --addon-id ID            Add-on ID to lock (default: contra@lotmik)
  --install-url URL        Install URL used in policy (default: AMO latest URL from add-on ID)
  --on-conflict MODE       Existing policies.json behavior: merge|overwrite|abort (default: merge)
  --firefox-path PATH      Firefox directory path or firefox.exe path (default: auto-detect)
  --yes, -y                Non-interactive mode (use selected/default options)
  -h, --help               Show help
"@
}

function Step([int]$Index, [string]$Message) {
  Write-Host "[$Index/6] $Message"
}

function Write-Utf8File([string]$Path, [string]$Content) {
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Read-JsonObject([string]$Path) {
  $raw = Get-Content -Path $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{}
  }

  try {
    $data = $raw | ConvertFrom-Json
  } catch {
    throw "Existing policies.json is invalid JSON."
  }

  if ($null -eq $data -or $data -isnot [System.Management.Automation.PSCustomObject]) {
    throw "Existing policies.json top-level must be a JSON object."
  }

  return $data
}

function Ensure-ObjectProperty($Parent, [string]$Name) {
  $property = $Parent.PSObject.Properties[$Name]
  if (
    $null -eq $property -or
    $null -eq $property.Value -or
    $property.Value -isnot [System.Management.Automation.PSCustomObject]
  ) {
    if ($null -ne $property) {
      $Parent.PSObject.Properties.Remove($Name)
    }
    $Parent | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{}) -Force
  }

  return $Parent.PSObject.Properties[$Name].Value
}

function Choose-ConflictModeInteractive {
  while ($true) {
    $choice = (Read-Host "Existing policies.json found. Choose [m]erge, [o]verwrite, or [a]bort (default: merge)").Trim().ToLowerInvariant()
    switch ($choice) {
      "" { return "merge" }
      "m" { return "merge" }
      "merge" { return "merge" }
      "o" { return "overwrite" }
      "overwrite" { return "overwrite" }
      "a" { return "abort" }
      "abort" { return "abort" }
      default { Write-Host "Invalid selection: $choice" }
    }
  }
}

function Resolve-FirefoxInstallDirectory([string]$OverridePath) {
  if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
    if (Test-Path -LiteralPath $OverridePath -PathType Leaf) {
      if ((Split-Path -Leaf $OverridePath).ToLowerInvariant() -eq "firefox.exe") {
        return (Split-Path -Parent $OverridePath)
      }
    }

    if (Test-Path -LiteralPath $OverridePath -PathType Container) {
      $firefoxExe = Join-Path $OverridePath "firefox.exe"
      if (Test-Path -LiteralPath $firefoxExe -PathType Leaf) {
        return $OverridePath
      }
    }

    throw "Invalid --firefox-path. Provide a Firefox install directory or path to firefox.exe."
  }

  $registryRoots = @(
    "HKLM:\SOFTWARE\Mozilla\Mozilla Firefox",
    "HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox"
  )

  foreach ($root in $registryRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
      continue
    }

    $currentVersion = (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue).CurrentVersion
    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
      continue
    }

    $mainPath = Join-Path $root "$currentVersion\Main"
    $installDir = (Get-ItemProperty -Path $mainPath -ErrorAction SilentlyContinue).'Install Directory'
    if (-not [string]::IsNullOrWhiteSpace($installDir)) {
      $firefoxExe = Join-Path $installDir "firefox.exe"
      if (Test-Path -LiteralPath $firefoxExe -PathType Leaf) {
        return $installDir
      }
    }
  }

  $fallbacks = @()
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $fallbacks += (Join-Path $env:ProgramFiles "Mozilla Firefox")
  }

  $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
  if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
    $fallbacks += (Join-Path $programFilesX86 "Mozilla Firefox")
  }

  foreach ($candidate in $fallbacks) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    $firefoxExe = Join-Path $candidate "firefox.exe"
    if (Test-Path -LiteralPath $firefoxExe -PathType Leaf) {
      return $candidate
    }
  }

  throw "Could not locate Firefox installation. Pass --firefox-path."
}

function Verify-PolicyInstall([string]$PolicyFile, [string]$AddonId, [string]$InstallUrl) {
  if (-not (Test-Path -LiteralPath $PolicyFile -PathType Leaf)) {
    throw "FAIL: policy file missing at $PolicyFile"
  }

  $data = Read-JsonObject -Path $PolicyFile

  $policies = $data.PSObject.Properties["policies"].Value
  if ($null -eq $policies -or $policies -isnot [System.Management.Automation.PSCustomObject]) {
    throw "FAIL: missing policies object"
  }

  $extensionSettings = $policies.PSObject.Properties["ExtensionSettings"].Value
  if ($null -eq $extensionSettings -or $extensionSettings -isnot [System.Management.Automation.PSCustomObject]) {
    throw "FAIL: missing policies.ExtensionSettings object"
  }

  $addonEntryProperty = $extensionSettings.PSObject.Properties[$AddonId]
  if ($null -eq $addonEntryProperty) {
    throw "FAIL: missing ExtensionSettings entry for $AddonId"
  }

  $addonEntry = $addonEntryProperty.Value
  if ($null -eq $addonEntry -or $addonEntry -isnot [System.Management.Automation.PSCustomObject]) {
    throw "FAIL: add-on policy entry is not an object"
  }

  $mode = [string]$addonEntry.PSObject.Properties["installation_mode"].Value
  if ($mode -ne "force_installed") {
    throw "FAIL: installation_mode is not force_installed"
  }

  $actualInstallUrl = [string]$addonEntry.PSObject.Properties["install_url"].Value
  if ($actualInstallUrl -ne $InstallUrl) {
    throw "FAIL: install_url does not match expected URL"
  }

  $privateBrowsingProperty = $addonEntry.PSObject.Properties["private_browsing"]
  $privateBrowsing = $null
  if ($null -ne $privateBrowsingProperty) {
    $privateBrowsing = $privateBrowsingProperty.Value
  }
  if ($privateBrowsing -ne $true) {
    throw "FAIL: private_browsing is not true"
  }

  Write-Host "PASS: policies.json is valid and Contra force-install policy is active."
}

$addonId = "contra@lotmik"
$installUrl = $null
$onConflict = "merge"
$onConflictExplicit = $false
$yesMode = $false
$firefoxPath = $null

for ($index = 0; $index -lt $args.Count; $index += 1) {
  $arg = [string]$args[$index]
  switch -Regex ($arg) {
    '^--addon-id$' {
      if ($index + 1 -ge $args.Count) { throw "Missing value for --addon-id" }
      $index += 1
      $addonId = [string]$args[$index]
      continue
    }
    '^--addon-id=(.+)$' {
      $addonId = [string]$Matches[1]
      continue
    }
    '^--install-url$' {
      if ($index + 1 -ge $args.Count) { throw "Missing value for --install-url" }
      $index += 1
      $installUrl = [string]$args[$index]
      continue
    }
    '^--install-url=(.+)$' {
      $installUrl = [string]$Matches[1]
      continue
    }
    '^--on-conflict$' {
      if ($index + 1 -ge $args.Count) { throw "Missing value for --on-conflict" }
      $index += 1
      $onConflict = [string]$args[$index]
      $onConflictExplicit = $true
      continue
    }
    '^--on-conflict=(.+)$' {
      $onConflict = [string]$Matches[1]
      $onConflictExplicit = $true
      continue
    }
    '^--firefox-path$' {
      if ($index + 1 -ge $args.Count) { throw "Missing value for --firefox-path" }
      $index += 1
      $firefoxPath = [string]$args[$index]
      continue
    }
    '^--firefox-path=(.+)$' {
      $firefoxPath = [string]$Matches[1]
      continue
    }
    '^--yes$|^-y$' {
      $yesMode = $true
      continue
    }
    '^--help$|^-h$' {
      Show-Usage
      exit 0
    }
    default {
      throw "Unknown argument: $arg"
    }
  }
}

if ([string]::IsNullOrWhiteSpace($addonId)) {
  throw "--addon-id cannot be empty."
}

$onConflict = $onConflict.Trim().ToLowerInvariant()
if ($onConflict -notin @("merge", "overwrite", "abort")) {
  throw "Invalid --on-conflict value: $onConflict. Use merge|overwrite|abort."
}

if ([string]::IsNullOrWhiteSpace($installUrl)) {
  $encodedAddonId = [System.Uri]::EscapeDataString($addonId)
  $installUrl = "https://addons.mozilla.org/firefox/downloads/latest/$encodedAddonId/latest.xpi"
}

if (-not ($installUrl.StartsWith("https://") -or $installUrl.StartsWith("file://"))) {
  throw "--install-url must start with https:// or file://"
}

try {
  Step 1 "Checking admin permissions and prerequisites"
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    throw "Run PowerShell as Administrator and re-run this script."
  }

  $effectiveConflictMode = $onConflict

  Step 2 "Detecting Firefox policy location"
  $firefoxInstallDir = Resolve-FirefoxInstallDirectory -OverridePath $firefoxPath
  $policyDir = Join-Path $firefoxInstallDir "distribution"
  $policyFile = Join-Path $policyDir "policies.json"

  Write-Host "Policy file target: $policyFile"
  Write-Host "Add-on ID: $addonId"
  Write-Host "Install URL: $installUrl"

  Step 3 "Preparing Contra policy payload"
  $targetData = [pscustomobject]@{
    policies = [pscustomobject]@{
      ExtensionSettings = [pscustomobject]@{
        $addonId = [pscustomobject]@{
          installation_mode = "force_installed"
          install_url = $installUrl
          private_browsing = $true
        }
      }
    }
  }

  Step 4 "Resolving existing policies.json conflicts"
  $finalData = $targetData
  if (Test-Path -LiteralPath $policyFile -PathType Leaf) {
    $backupDir = Join-Path $policyDir "contra-policy-backups"
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $backupPath = Join-Path $backupDir "policies-$timestamp.json"
    Copy-Item -LiteralPath $policyFile -Destination $backupPath -Force
    Write-Host "Backup created: $backupPath"

    if (-not $onConflictExplicit -and -not $yesMode) {
      $effectiveConflictMode = Choose-ConflictModeInteractive
    }

    switch ($effectiveConflictMode) {
      "abort" {
        Write-Host "Install aborted by user choice after backup."
        exit 0
      }
      "overwrite" {
        $finalData = $targetData
      }
      "merge" {
        $existingData = Read-JsonObject -Path $policyFile
        $policies = Ensure-ObjectProperty -Parent $existingData -Name "policies"
        $extensionSettings = Ensure-ObjectProperty -Parent $policies -Name "ExtensionSettings"
        $extensionSettings.PSObject.Properties.Remove($addonId) | Out-Null
        $extensionSettings | Add-Member -NotePropertyName $addonId -NotePropertyValue ([pscustomobject]@{
          installation_mode = "force_installed"
          install_url = $installUrl
          private_browsing = $true
        }) -Force
        $finalData = $existingData
      }
    }
  }

  Step 5 "Writing policies.json"
  New-Item -Path $policyDir -ItemType Directory -Force | Out-Null
  $json = $finalData | ConvertTo-Json -Depth 100
  Write-Utf8File -Path $policyFile -Content $json

  Step 6 "Verifying installation"
  Verify-PolicyInstall -PolicyFile $policyFile -AddonId $addonId -InstallUrl $installUrl

  Write-Host ""
  Write-Host "Hardcore Mode install complete."
  Write-Host "Next steps:"
  Write-Host "  1. Restart Firefox completely."
  Write-Host "  2. Open about:policies and confirm Status is Active."
  Write-Host "  3. Confirm ExtensionSettings contains $addonId."
}
catch {
  Write-Error $_
  exit 1
}
