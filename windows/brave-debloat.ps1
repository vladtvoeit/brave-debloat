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
    Remove the policies this script set. Without -UserOnly this clears both
    HKLM and HKCU, since a machine may carry leftovers from an earlier
    -UserOnly run; each hive is reported separately.

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
    # -NoExit keeps the elevated window up, otherwise it closes the moment the
    # script ends and the output is gone before it can be read.
    $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $argList = @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $Arguments
    Start-Process $exe -Verb RunAs -ArgumentList $argList
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
        # Write-then-replace: writing over $Path directly would leave it
        # truncated if serialisation failed partway.
        $out = $doc | ConvertTo-Json -Depth 100 -Compress
        $tmp = "$Path.tmp-$Stamp"
        [IO.File]::WriteAllText($tmp, $out, (New-Object Text.UTF8Encoding $false))

        # Move-Item -Force, not [IO.File]::Replace: PowerShell binds $null
        # to the backup-path parameter as an empty string, which Replace
        # rejects. On one volume this is a single rename either way.
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        Write-Warn "skipped $(Split-Path $Path -Leaf): $($_.Exception.Message)"
        return
    }

    $rel = if ($Path.StartsWith($DataDir)) { $Path.Substring($DataDir.Length).TrimStart('\') } else { $Path }
    Write-Ok $rel
}

# -----------------------------------------------------------------------------
#  Uninstall
# -----------------------------------------------------------------------------
if ($Uninstall) {
    if (-not $UserOnly -and -not (Test-Admin)) { Request-Elevation -Arguments @('-Uninstall') }

    Write-Head 'Removing policies'
    $targets = @($PolicyKey)
    if (-not $UserOnly) { $targets += 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave' }

    $total = 0
    foreach ($key in $targets) {
        if (-not (Test-Path $key)) { continue }

        # Counted per hive: a single total would hide which one was touched,
        # and a plain -Uninstall deliberately clears HKCU as well.
        $n = 0
        foreach ($name in $Policies.Keys) {
            if ($null -ne (Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue)) {
                Remove-ItemProperty -Path $key -Name $name -Force
                $n++
            }
        }
        $total += $n

        # The key may hold policies this script never set - an admin's own
        # DnsOverHttpsMode, ExtensionInstallForcelist and so on. Drop the key
        # itself only once nothing is left in it.
        $left = @((Get-Item $key).Property)
        $subs = @(Get-ChildItem $key -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0 -and $subs.Count -eq 0) {
            Remove-Item -Path $key -Force
            Write-Ok "$key - $n removed, key was left empty and deleted"
        } else {
            Write-Ok "$key - $n removed, $($left.Count) unrelated values left untouched"
        }
    }
    if ($total -eq 0) { Write-Warn 'none of this script''s policies were present' }
    Write-Host ''
    Write-Host 'Profile preferences are not reverted automatically.'
    Write-Host "Restore a *.bak-* file next to Preferences / Local State if needed."
    return
}

# Elevate before touching anything, so Brave is not closed twice.
if (-not $UserOnly -and -not (Test-Admin)) {
    $fwd = @()
    if ($Sponsored) { $fwd += '-Sponsored' }
    Request-Elevation -Arguments $fwd
}

# -----------------------------------------------------------------------------
#  Quit Brave — it rewrites its preference files on exit
# -----------------------------------------------------------------------------
$brave = Get-Process -Name 'brave' -ErrorAction SilentlyContinue
if ($brave) {
    Write-Head 'Quitting Brave'
    $brave | ForEach-Object { $_.CloseMainWindow() | Out-Null }

    # Brave flushes Preferences on exit; killing it mid-write is how profiles
    # get corrupted. Give it up to 10s, force only if it hangs.
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Process -Name 'brave' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    $still = Get-Process -Name 'brave' -ErrorAction SilentlyContinue
    if ($still) {
        Write-Warn 'still running after 10s - forcing'
        $still | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

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

    $junk = @(Join-Path $DataDir 'sponsored-images')
    Get-ChildItem -LiteralPath $DataDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object {
            $junk += (Join-Path $_.FullName 'ads_service')
            $junk += (Join-Path $_.FullName 'sponsored-images')
        }
    foreach ($path in $junk) {
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
