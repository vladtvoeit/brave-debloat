<#
.SYNOPSIS
    brave-debloat for Windows.

.DESCRIPTION
    Disables Brave Rewards/BAT, Wallet, VPN upsell, Leo AI, News, Talk,
    Playlist, Speedreader, Wayback Machine, Tor, IPFS, and telemetry
    (P3A, daily usage ping, Web Discovery, crash reports, promo tabs).

    Policies are written to HKLM:\SOFTWARE\Policies\BraveSoftware\Brave,
    which is where Brave reads its group-policy settings from. Toolbar
    buttons and a few toggles that have no policy equivalent are patched
    in the profile's Preferences / Local State files.

    Shields and auto-updates are never touched.

.PARAMETER Sponsored
    Also disable sponsored (ad) wallpapers on the new tab page. Brave's own
    stock photos are never touched.

.PARAMETER UserOnly
    Write policies to HKCU instead of HKLM. No administrator rights needed.
    Brave honours both; machine-wide policies are the stronger of the two.

.PARAMETER Uninstall
    Remove the policies this script set.

.EXAMPLE
    .\brave-debloat.ps1

.EXAMPLE
    .\brave-debloat.ps1 -UserOnly
#>

[CmdletBinding()]
param(
    [switch]$Sponsored,
    [switch]$UserOnly,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$PolicyKey = if ($UserOnly) { 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave' }
             else           { 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' }
$DataDir   = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
$Stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Head { param([string]$Text) Write-Host "==> $Text" -ForegroundColor White }
function Write-Ok   { param([string]$Text) Write-Host '   OK  ' -ForegroundColor Green -NoNewline; Write-Host $Text }
function Write-Warn { param([string]$Text) Write-Host '   !   ' -ForegroundColor Yellow -NoNewline; Write-Host $Text }

# -----------------------------------------------------------------------------
#  Policy set. Brave reads these as DWORDs: 1 = on, 0 = off.
# -----------------------------------------------------------------------------
$Policies = [ordered]@{
    # Crypto, ads, upsells
    BraveRewardsDisabled                    = 1
    BraveWalletDisabled                     = 1
    BraveVPNDisabled                        = 1
    BraveAIChatEnabled                      = 0
    BraveNewsDisabled                       = 1
    BraveTalkDisabled                       = 1
    BravePlaylistEnabled                    = 0
    BraveSpeedreaderEnabled                 = 0
    BraveWaybackMachineEnabled              = 0
    TorDisabled                             = 1
    IPFSEnabled                             = 0

    # Brave telemetry
    BraveP3AEnabled                         = 0
    BraveStatsPingEnabled                   = 0
    BraveWebDiscoveryEnabled                = 0

    # Chromium telemetry and promos
    MetricsReportingEnabled                 = 0
    SafeBrowsingExtendedReportingEnabled    = 0
    UrlKeyedAnonymizedDataCollectionEnabled = 0
    FeedbackSurveysEnabled                  = 0
    PromotionalTabsEnabled                  = 0
    BackgroundModeEnabled                   = 0
    DefaultBrowserSettingEnabled            = 0
    SpellCheckServiceEnabled                = 0
    NetworkPredictionOptions                = 2

    # Privacy Sandbox - Chromium's own ad-targeting stack
    PrivacySandboxAdMeasurementEnabled      = 0
    PrivacySandboxPromptEnabled             = 0
    PrivacySandboxSiteEnabledAdsEnabled     = 0
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-launch elevated when writing machine-wide policies. Piped invocations
# (irm … | iex) have no $PSCommandPath to relaunch, so those are told what
# to do instead.
function Request-Elevation {
    param([string[]]$Arguments)

    if (-not $PSCommandPath) {
        throw 'Machine-wide policies need administrator rights, and this script was piped in rather than saved, so it cannot relaunch itself. Either open PowerShell as administrator and run the same command again, or pass -UserOnly to write user-level policies instead.'
    }

    Write-Head 'Requesting administrator rights (UAC)'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $Arguments
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

# Brave's Preferences files store dotted keys as nested objects.
function Set-DeepValue {
    param($Root, [string]$Path, $Value)
    $parts = $Path.Split('.')
    $cur = $Root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $name = $parts[$i]
        $next = $cur.PSObject.Properties[$name]
        if ($null -eq $next -or $next.Value -isnot [PSCustomObject]) {
            $cur | Add-Member -NotePropertyName $name -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $cur = $cur.$name
    }
    $cur | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value -Force
}

function Update-PrefsFile {
    param([string]$Path, [hashtable]$Prefs)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $doc  = $json | ConvertFrom-Json
    } catch {
        Write-Warn "skipped $(Split-Path $Path -Leaf): $($_.Exception.Message)"
        return
    }

    try {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-$Stamp" -Force
        foreach ($key in $Prefs.Keys) { Set-DeepValue -Root $doc -Path $key -Value $Prefs[$key] }

        # Depth must be generous: Brave's Preferences nest well past the default
        # of 2, and anything deeper would be silently flattened to a string.
        # No BOM either — Chromium refuses to parse a file that starts with one.
        $out = $doc | ConvertTo-Json -Depth 100 -Compress
        [IO.File]::WriteAllText($Path, $out, (New-Object Text.UTF8Encoding $false))
    } catch {
        Write-Warn "skipped $(Split-Path $Path -Leaf): $($_.Exception.Message)"
        return
    }

    Write-Ok (Split-Path $Path -Leaf)
}

# -----------------------------------------------------------------------------
#  Uninstall
# -----------------------------------------------------------------------------
if ($Uninstall) {
    if (-not $UserOnly -and -not (Test-Admin)) { Request-Elevation -Arguments @('-Uninstall') }

    Write-Head 'Removing policies'
    $found = $false
    foreach ($key in @($PolicyKey, 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave')) {
        if (Test-Path $key) {
            Remove-Item -Path $key -Recurse -Force
            Write-Ok $key
            $found = $true
        }
    }
    if (-not $found) { Write-Warn 'no policy key found' }
    Write-Host ''
    Write-Host 'Profile preferences are not reverted automatically.'
    Write-Host "Restore a *.bak-* file next to Preferences / Local State if needed."
    return
}

# Elevate before touching anything, so Brave is not closed twice.
if (-not $UserOnly -and -not (Test-Admin)) { Request-Elevation -Arguments @() }

# -----------------------------------------------------------------------------
#  Quit Brave — it rewrites its preference files on exit
# -----------------------------------------------------------------------------
Write-Head 'Quitting Brave'
Get-Process -Name 'brave' -ErrorAction SilentlyContinue | ForEach-Object {
    $_.CloseMainWindow() | Out-Null
}
Start-Sleep -Seconds 2
Get-Process -Name 'brave' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# -----------------------------------------------------------------------------
#  1. Registry policies
# -----------------------------------------------------------------------------
Write-Head 'Applying policies'
if (-not (Test-Path $PolicyKey)) { New-Item -Path $PolicyKey -Force | Out-Null }
foreach ($name in $Policies.Keys) {
    New-ItemProperty -Path $PolicyKey -Name $name -Value $Policies[$name] `
                     -PropertyType DWord -Force | Out-Null
}
Write-Ok "$($Policies.Count) policies written to $PolicyKey"
if ($UserOnly) { Write-Warn 'user-level policies; machine-wide ones override these if present' }
Write-Host ''

# -----------------------------------------------------------------------------
#  2. Profile preferences — toolbar buttons and other non-policy toggles
# -----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $DataDir)) {
    Write-Warn 'Brave profile not found — skipping profile preferences'
} else {
    Write-Head "Patching profile preferences (backups: *.bak-$Stamp)"

    $profilePrefs = @{
        'brave.new_tab_page.show_brave_today'          = $false
        'brave.new_tab_page.show_brave_news'           = $false
        'brave.today.enabled'                          = $false
        'browser.check_default_browser'                = $false
        'brave.rewards.show_brave_rewards_button'      = $false
        'brave.rewards.show_button'                    = $false
        'brave.wallet.show_wallet_icon_on_toolbar'     = $false
        'brave.vpn.show_button'                        = $false
        'brave.ai_chat.enabled_by_user'                = $false
        'brave.ai_chat.autocomplete_provider_enabled'  = $false
        'brave.playlist.enabled'                       = $false
        'brave.speedreader.enabled'                    = $false
        'brave.wayback_machine_enabled'                = $false
        'ipfs.ipfs_enabled'                            = $false
        'brave.p3a.enabled'                            = $false
        'brave.stats.ping_enabled'                     = $false
    }

    # Opt-in: these cover sponsored (ad) wallpapers only. Brave's own stock
    # photos are controlled by show_background_image, which is never touched.
    if ($Sponsored) {
        $profilePrefs['brave.new_tab_page.show_sponsored_images']          = $false
        $profilePrefs['brave.new_tab_page.show_branded_wallpaper']         = $false
        $profilePrefs['brave.new_tab_page.branded_wallpaper_notification'] = $false
    }

    $localState = @{
        'brave.p3a.enabled'            = $false
        'brave.p3a.notice_acknowledged' = $true
        'brave.stats.ping_enabled'     = $false
        'brave.rewards.enabled'        = $false
        'brave.web_discovery.enabled'  = $false
    }

    Get-ChildItem -LiteralPath $DataDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object { Update-PrefsFile -Path (Join-Path $_.FullName 'Preferences') -Prefs $profilePrefs }

    Update-PrefsFile -Path (Join-Path $DataDir 'Local State') -Prefs $localState

    foreach ($junk in @('Default\ads_service', 'sponsored-images', 'Default\sponsored-images')) {
        $path = Join-Path $DataDir $junk
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Ok 'ad cache cleared'
}

Write-Host ''
Write-Host 'Done. Restart Brave.' -ForegroundColor White
Write-Host ''
Write-Host '  Verify:  brave://policy    - every policy listed, status OK'
Write-Host '           brave://settings  - Rewards / Wallet / VPN / Leo are gone'
Write-Host ''
Write-Host '  Revert:  .\brave-debloat.ps1 -Uninstall'
