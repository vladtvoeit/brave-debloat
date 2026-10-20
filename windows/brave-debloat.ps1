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
    [switch]$Uninstall,

    # Set automatically when the script relaunches itself through UAC. If the
    # user is a standard account and types a separate admin's credentials, the
    # elevated process gets that admin's LOCALAPPDATA, and without this it
    # would patch the wrong profile.
    [string]$DataDirOverride,

    # Also set automatically on relaunch: how many HKCU values the unelevated
    # process already removed. Without it the elevated run walks HKCU a second
    # time, finds nothing, and contradicts what was just printed.
    [int]$HkcuCleared = -1
)

$ErrorActionPreference = 'Stop'
$BraveAlive = $false

$PolicyKey = if ($UserOnly) { 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave' }
             else           { 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' }
$DataDir   = if ($DataDirOverride) { $DataDirOverride }
             else { Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data' }
# A trailing backslash would escape the closing quote when this is handed to
# the elevated process on the command line.
$DataDir   = $DataDir.TrimEnd('\')
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
    BraveLocalAIEnabled                     = 0   # on-device AI, downloads a model
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

# Which profile a path belongs to, for messages. Ordinal-insensitive because
# -DataDirOverride may arrive spelled differently than $_.FullName.
function Get-RelativePath {
    param([string]$Path)
    if ($Path.StartsWith($DataDir, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($DataDir.Length).TrimStart('\')
    }
    return $Path
}

function Update-PrefsFile {
    param([string]$Path, [hashtable]$Prefs)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $doc  = $json | ConvertFrom-Json
    } catch {
        # This is where PowerShell 5.1's ConvertFrom-Json gives out, and it
        # does so on things Chromium legitimately writes: an empty-string
        # dictionary key, keys differing only in case, and anything past the
        # 2 MB JavaScriptSerializer limit.
        Write-Warn "NOT PATCHED - $(Get-RelativePath $Path): $($_.Exception.Message)"
        return
    }

    # An empty file does not throw; ConvertFrom-Json just returns $null, and
    # the failure would surface later as a confusing error inside Set-DeepValue.
    if ($null -eq $doc) {
        Write-Warn "NOT PATCHED - $(Get-RelativePath $Path): file is empty"
        return
    }

    try {
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
        # Only now that the replacement exists on disk is it safe to touch the
        # backups. Rotating first meant two failed runs in a row could discard
        # both surviving copies while writing nothing.
        #
        # -LiteralPath with -Filter, not a wildcard path: a profile directory
        # may contain [ or ], which PowerShell would read as a range.
        $dir  = Split-Path -LiteralPath $Path
        $leaf = Split-Path -LiteralPath $Path -Leaf
        $stamped = @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.bak-2*" -ErrorAction SilentlyContinue |
                     Sort-Object Name)
        $initial = "$Path.bak-initial"
        $firstEver = (-not $stamped.Count) -and (-not (Test-Path -LiteralPath $initial))

        if (-not (Test-Path -LiteralPath $initial)) {
            $source = if ($stamped.Count) { $stamped[0].FullName } else { $Path }
            Copy-Item -LiteralPath $source -Destination $initial -Force
        }

        # On a first run the initial copy is this same file; a second identical
        # one would be noise.
        if (-not $firstEver) {
            Copy-Item -LiteralPath $Path -Destination "$Path.bak-$Stamp" -Force
        }

        $stamped = @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.bak-2*" -ErrorAction SilentlyContinue |
                     Sort-Object Name)
        if ($stamped.Count -gt 2) {
            $stamped[0..($stamped.Count - 3)] | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        Write-Warn "NOT PATCHED - $(Get-RelativePath $Path): $($_.Exception.Message)"
        return
    }

    Write-Ok (Get-RelativePath $Path)
}

# -----------------------------------------------------------------------------
#  Uninstall
# -----------------------------------------------------------------------------
if ($Uninstall) {
    # HKCU must be cleared before elevating: a standard user who types a
    # separate admin's password gets that admin's hive afterwards, and their
    # own user-level policies would survive untouched.
    $hkcu = 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave'
    if (-not $UserOnly -and -not (Test-Admin) -and (Test-Path $hkcu)) {
        $n = 0
        foreach ($name in $Policies.Keys) {
            if ($null -ne (Get-ItemProperty -Path $hkcu -Name $name -ErrorAction SilentlyContinue)) {
                Remove-ItemProperty -Path $hkcu -Name $name -Force
                $n++
            }
        }
        if ($n) { Write-Ok "$hkcu - $n removed (before elevating)" }
        $script:HkcuCleared = $n
        if (-not @((Get-Item $hkcu).Property).Count -and
            -not @(Get-ChildItem $hkcu -ErrorAction SilentlyContinue).Count) {
            Remove-Item -Path $hkcu -Force
        }
    }

    if (-not $UserOnly -and -not (Test-Admin)) {
        $fwd = @('-Uninstall')
        if ($HkcuCleared -ge 0) { $fwd += @('-HkcuCleared', $HkcuCleared) }
        Request-Elevation -Arguments $fwd
    }

    Write-Head 'Removing policies'
    $targets = @($PolicyKey)
    # Skip HKCU when the unelevated process already handled it; its hive may
    # not even be the one this process can see.
    if (-not $UserOnly -and $HkcuCleared -lt 0) {
        $targets += 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave'
    }

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
            $kept = @()
            if ($left.Count) { $kept += "$($left.Count) values" }
            if ($subs.Count) { $kept += "$($subs.Count) subkeys" }
            Write-Ok "$key - $n removed, $($kept -join ' and ') left untouched"
        }
    }
    if ($HkcuCleared -gt 0) {
        Write-Ok "HKCU - $HkcuCleared removed before elevating"
        $total += $HkcuCleared
    }
    if ($total -eq 0) { Write-Warn 'none of this script''s policies were present' }
    Write-Host ''
    Write-Host 'Profile preferences are not reverted automatically.'
    Write-Host "Restore *.bak-initial next to Preferences / Local State for the state"
    Write-Host "from before this script first ran, or a *.bak-<timestamp> copy."
    return
}

# Elevate before touching anything, so Brave is not closed twice.
if (-not $UserOnly -and -not (Test-Admin)) {
    $fwd = @('-DataDirOverride', "`"$DataDir`"")
    if ($Sponsored) { $fwd += '-Sponsored' }
    Request-Elevation -Arguments $fwd
}

# -----------------------------------------------------------------------------
#  Quit Brave — it rewrites its preference files on exit
# -----------------------------------------------------------------------------
# Only this session's Brave: Get-Process spans every logged-in user, so with
# Fast User Switching or RDP the script would kill someone else's browser, or
# wait on one it cannot close.
$sessionId = (Get-Process -Id $PID).SessionId
$brave = @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue |
           Where-Object { $_.SessionId -eq $sessionId })
if ($brave) {
    Write-Head 'Quitting Brave'
    # CloseMainWindow closes one window; with several open, the next becomes
    # the main one, so this keeps asking until they are gone. Brave flushes
    # Preferences on exit and killing it mid-write corrupts profiles.
    $hadWindow = @($brave | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0
    $deadline = (Get-Date).AddSeconds(10)
    while ($hadWindow -and (Get-Date) -lt $deadline) {
        $procs = @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue |
                   Where-Object { $_.SessionId -eq $sessionId })
        if (-not $procs) { break }
        foreach ($proc in $procs) {
            # The process can exit between Get-Process and here, and
            # $ErrorActionPreference = 'Stop' would make that fatal.
            try {
                $proc.Refresh()
                if ($proc.MainWindowHandle -ne 0) { $proc.CloseMainWindow() | Out-Null }
            } catch { }
        }
        Start-Sleep -Milliseconds 300
    }
    # A window closing frees its handle before the browser finishes flushing
    # Preferences, so give it a moment rather than killing mid-write.
    if ($hadWindow) { Start-Sleep -Seconds 2 }

    $still = @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue |
               Where-Object { $_.SessionId -eq $sessionId })
    if ($still) {
        # No window to close means background mode (tray), where nothing short
        # of a kill will do; Brave shows a "did not shut down correctly" bar.
        Write-Warn 'no window would close (background mode?) - forcing'
        $still | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    if (@(Get-Process -Name 'brave' -ErrorAction SilentlyContinue |
          Where-Object { $_.SessionId -eq $sessionId })) {
        $script:BraveAlive = $true
        Write-Warn 'could not quit Brave - profile preferences will be skipped,'
        Write-Warn 'it would overwrite them on exit. Policies still apply.'
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
if ($BraveAlive) {
    # Already warned above: Brave is still running and would overwrite this.
} elseif (-not (Test-Path -LiteralPath $DataDir)) {
    Write-Warn 'Brave profile not found — skipping profile preferences'
} else {
    Write-Head "Patching profile preferences (backups: *.bak-$Stamp)"

    # Every name here is verified against brave-core. A wrong one is silent:
    # Chromium stores only prefs that differ from their default, so an
    # invented key and an untouched real key look identical on disk.
    $profilePrefs = @{
        'brave.new_tab_page.show_brave_news'          = $false
        'brave.today.opted_in'                        = $false
        'brave.today.should_show_toolbar_button'      = $false
        'brave.rewards.show_brave_rewards_button_in_location_bar' = $false
        'brave.rewards.enabled'                       = $false
        'brave.wallet.show_wallet_icon_on_toolbar'    = $false
        'brave.brave_vpn.show_button'                 = $false
        'brave.new_tab_page.show_rewards'              = $false
        'brave.new_tab_page.show_brave_vpn'            = $false
        'brave.new_tab_page.show_together'             = $false
        'brave.ai_chat.show_toolbar_button'           = $false
        'brave.ai_chat.autocomplete_provider_enabled' = $false
        'brave.playlist.enabled'                      = $false
        'brave.web_discovery_enabled'                 = $false
        'browser.check_default_browser'               = $false  # upstream Chromium
    }

    # Opt-in. Sponsored wallpapers are ads; Brave's own stock photos are left
    # alone - those are brave.new_tab_page.show_background_image, never written.
    if ($Sponsored) {
        $profilePrefs['brave.brave_ads.sponsored.enabled'] = $false
        # Retired in 08/2026 but still migrated into the pref above, so it
        # keeps older builds covered.
        $profilePrefs['brave.new_tab_page.show_branded_background_image'] = $false
        $profilePrefs['brave.branded_wallpaper_notification_dismissed']   = $true
    }

    $localState = @{
        'brave.p3a.enabled'               = $false
        'brave.p3a.notice_acknowledged'   = $true
        'brave.stats.reporting_enabled'   = $false
    }

    Get-ChildItem -LiteralPath $DataDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object { Update-PrefsFile -Path (Join-Path $_.FullName 'Preferences') -Prefs $profilePrefs }

    Update-PrefsFile -Path (Join-Path $DataDir 'Local State') -Prefs $localState

    # "sponsored-images" is a chrome:// URL path inside Brave, not a directory,
    # so only ads_service is ever present - and usually it is not.
    $cleared = 0
    Get-ChildItem -LiteralPath $DataDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object {
            $ads = Join-Path $_.FullName 'ads_service'
            if (Test-Path -LiteralPath $ads) {
                Remove-Item -LiteralPath $ads -Recurse -Force -ErrorAction SilentlyContinue
                # SilentlyContinue swallows a locked directory, so confirm.
                if (-not (Test-Path -LiteralPath $ads)) { $cleared++ }
            }
        }
    if ($cleared) { Write-Ok "ad cache cleared ($cleared)" }
}

Write-Host ''
Write-Host 'Done. Restart Brave.' -ForegroundColor White
Write-Host ''
Write-Host '  Verify:  brave://policy    - every policy listed, status OK'
Write-Host '           brave://settings  - Rewards / Wallet / VPN / Leo are gone'
Write-Host ''
Write-Host '  Revert:  .\brave-debloat.ps1 -Uninstall'
