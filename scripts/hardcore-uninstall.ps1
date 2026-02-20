$ErrorActionPreference = "Stop"

function Show-Usage {
  @"
Usage: scripts/hardcore-uninstall.ps1 [options]

Remove Contra Firefox enterprise policy lock while preserving unrelated policies.

Options:
  --addon-id ID            Add-on ID to unlock (default: contra@lotmik)
  --firefox-path PATH      Firefox directory path or firefox.exe path (default: auto-detect)
  --yes, -y                Non-interactive mode
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

function Verify-PolicyUninstall([string]$PolicyFile, [string]$AddonId) {
  if (-not (Test-Path -LiteralPath $PolicyFile -PathType Leaf)) {
    Write-Host "PASS: policies.json removed (no active enterprise policies in this file)."
    return
  }

  $data = Read-JsonObject -Path $PolicyFile
  $policies = $data.PSObject.Properties["policies"].Value
  if ($null -eq $policies -or $policies -isnot [System.Management.Automation.PSCustomObject]) {
    Write-Host "PASS: policies.json remains valid without a policies object for Contra."
    return
  }

  $extensionSettings = $policies.PSObject.Properties["ExtensionSettings"].Value
  if ($null -eq $extensionSettings -or $extensionSettings -isnot [System.Management.Automation.PSCustomObject]) {
    Write-Host "PASS: ExtensionSettings not present; Contra is not force-installed by policy."
    return
  }

  if ($null -ne $extensionSettings.PSObject.Properties[$AddonId]) {
    throw "FAIL: ExtensionSettings still contains $AddonId"
  }

  Write-Host "PASS: Contra policy entry is removed and remaining policies are valid JSON."
}

$addonId = "contra@lotmik"
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

try {
  Step 1 "Checking admin permissions and prerequisites"
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    throw "Run PowerShell as Administrator and re-run this script."
  }

  Step 2 "Detecting Firefox policy location"
  $firefoxInstallDir = Resolve-FirefoxInstallDirectory -OverridePath $firefoxPath
  $policyDir = Join-Path $firefoxInstallDir "distribution"
  $policyFile = Join-Path $policyDir "policies.json"

  Write-Host "Policy file target: $policyFile"
  Write-Host "Add-on ID: $addonId"

  Step 3 "Checking current policy file and creating backup"
  if (-not (Test-Path -LiteralPath $policyFile -PathType Leaf)) {
    Write-Host "No policies.json found. Nothing to uninstall for Contra."
    Write-Host ""
    Write-Host "Hardcore Mode uninstall complete."
    Write-Host "Next steps:"
    Write-Host "  1. Restart Firefox completely."
    Write-Host "  2. Open about:policies and confirm no Contra force-install entry remains."
    exit 0
  }

  $backupDir = Join-Path $policyDir "contra-policy-backups"
  New-Item -Path $backupDir -ItemType Directory -Force | Out-Null

  $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
  $backupPath = Join-Path $backupDir "policies-$timestamp.json"
  Copy-Item -LiteralPath $policyFile -Destination $backupPath -Force
  Write-Host "Backup created: $backupPath"

  Step 4 "Removing Contra policy entry"
  $data = Read-JsonObject -Path $policyFile
  $removed = $false

  $policies = $data.PSObject.Properties["policies"].Value
  if ($null -ne $policies -and $policies -is [System.Management.Automation.PSCustomObject]) {
    $extensionSettings = $policies.PSObject.Properties["ExtensionSettings"].Value
    if ($null -ne $extensionSettings -and $extensionSettings -is [System.Management.Automation.PSCustomObject]) {
      if ($null -ne $extensionSettings.PSObject.Properties[$addonId]) {
        $extensionSettings.PSObject.Properties.Remove($addonId)
        $removed = $true
      }

      if ($extensionSettings.PSObject.Properties.Count -eq 0) {
        $policies.PSObject.Properties.Remove("ExtensionSettings")
      }
    }

    if ($policies.PSObject.Properties.Count -eq 0) {
      $data.PSObject.Properties.Remove("policies")
    }
  }

  Step 5 "Writing updated policies"
  if ($data.PSObject.Properties.Count -eq 0) {
    Remove-Item -LiteralPath $policyFile -Force
    Write-Host "Removed $policyFile because it no longer contains policies."
  } else {
    $json = $data | ConvertTo-Json -Depth 100
    Write-Utf8File -Path $policyFile -Content $json
    if ($removed) {
      Write-Host "Removed Contra entry from $policyFile."
    } else {
      Write-Host "Contra entry was not present; kept other policies unchanged in $policyFile."
    }
  }

  Step 6 "Verifying uninstall"
  Verify-PolicyUninstall -PolicyFile $policyFile -AddonId $addonId

  Write-Host ""
  Write-Host "Hardcore Mode uninstall complete."
  Write-Host "Next steps:"
  Write-Host "  1. Restart Firefox completely."
  Write-Host "  2. Open about:policies and confirm Contra is not listed under ExtensionSettings."
}
catch {
  Write-Error $_
  exit 1
}
