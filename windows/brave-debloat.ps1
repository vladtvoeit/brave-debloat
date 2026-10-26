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
    Write policies to HKCU instead of HKLM, so they apply to this account
    rather than the machine. Brave honours both, and machine-wide policies win
    where they overlap. This still needs administrator rights: Windows
    restricts HKCU\SOFTWARE\Policies to administrators.

.PARAMETER Uninstall
    Remove the policies this script set. Without -UserOnly this clears both
    HKLM and HKCU, since a machine may carry leftovers from an earlier
    -UserOnly run; each hive is reported separately.

.EXAMPLE
    .\brave-debloat.ps1

.EXAMPLE
    .\brave-debloat.ps1 -UserOnly
#>

# PositionalBinding is off deliberately. With it on, $DataDirOverride picks up
# position 0, and PowerShell does not recognise a token starting with -- or /
# as a parameter name. Someone typing --uninstall out of habit from the macOS
# script would have it bound there as a path, leaving $Uninstall false: the
# script would then install everything and report that no Brave profile was
# found in a directory called "--uninstall".
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Sponsored,
    [switch]$UserOnly,
    [switch]$Uninstall,

    # Set automatically when the script relaunches itself through UAC. If the
    # user is a standard account and types a separate admin's credentials, the
    # elevated process gets that admin's LOCALAPPDATA, and without this it
    # would patch the wrong profile.
    [Parameter(DontShow)]
    [string]$DataDirOverride
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

# Policies this script used to set and Chromium has since removed. A removed
# policy shows as Error in brave://policy, so it is deleted on every run and on
# -Uninstall, from wherever an earlier version of the script put it.
$RetiredPolicies = @(
    'SafeBrowsingExtendedReportingEnabled'   # unsupported after M144
)

# throw dumps a stack trace, CategoryInfo and FullyQualifiedErrorId over the
# message. For something a person reads and acts on, that is noise.
function Stop-WithReason {
    param([string[]]$Lines)
    Write-Host ''
    foreach ($line in $Lines) { Write-Host "  $line" -ForegroundColor Yellow }
    Write-Host ''

    # exit would be right for a script file, but under `irm ... | iex` this
    # code runs in the caller's own scope, where exit closes their console the
    # instant the message appears. throw ends the run without taking the
    # window with it; the explanation is already printed above, so the error
    # line can stay short.
    if ($PSCommandPath) { exit 1 }
    throw 'brave-debloat stopped - see the explanation above.'
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-launch elevated when writing machine-wide policies. Piped invocations
# (irm ... | iex) have no $PSCommandPath to relaunch, so those are told what
# to do instead.
function Request-Elevation {
    param([string[]]$Arguments)

    if (-not $PSCommandPath) {
        Stop-WithReason @(
            'Policies need administrator rights, and this script was piped in'
            'rather than saved, so it cannot relaunch itself.'
            ''
            'Open PowerShell as administrator and run the same command again.'
            ''
            '-UserOnly does not avoid this: Windows restricts'
            'HKCU\SOFTWARE\Policies to administrators as well. It changes the'
            'scope from machine-wide to this account, not the privilege.'
        )
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
        # Where PowerShell 5.1's ConvertFrom-Json gives out. Measured on
        # 5.1.26100: an empty-string dictionary key and two keys differing
        # only in case both throw, because the cmdlet builds a PSCustomObject
        # and property names there are case-insensitive and cannot be empty.
        # A 3 MB document parses fine, so the 2 MB limit often cited for this
        # does not apply to reading. No real Brave profile has been seen to
        # contain either construct; if one turns up, the fix is to deserialise
        # into a dictionary rather than a PSCustomObject -- on 5.1 via
        # JavaScriptSerializer, which PowerShell 7 does not have and does not
        # need.
        Write-Warn "NOT PATCHED - $(Get-RelativePath $Path): $($_.Exception.Message.Trim())"
        return
    }

    # An empty file does not throw; ConvertFrom-Json just returns $null, and
    # the failure would surface later as a confusing error inside Set-DeepValue.
    if ($null -eq $doc) {
        Write-Warn "NOT PATCHED - $(Get-RelativePath $Path): file is empty"
        return
    }

    $tmp = "$Path.tmp-$Stamp"
    $made = $null
    $replaced = $false
    try {
        foreach ($key in $Prefs.Keys) { Set-DeepValue -Root $doc -Path $key -Value $Prefs[$key] }

        # Depth must be generous: Brave's Preferences nest well past the default
        # of 2, and anything deeper would be silently flattened to a string.
        # No BOM either - Chromium refuses to parse a file that starts with one.
        # Write-then-replace: writing over $Path directly would leave it
        # truncated if serialisation failed partway.
        $out = $doc | ConvertTo-Json -Depth 100 -Compress
        [IO.File]::WriteAllText($tmp, $out, (New-Object Text.UTF8Encoding $false))

        # Backups. The copy of the current file has to be taken before it is
        # replaced, but nothing is deleted until after: see the rotation below.
        #
        # -LiteralPath with -Filter, not a wildcard path: a profile directory
        # may contain [ or ], which PowerShell would read as a range.
        # [IO.Path], not Split-Path: in PowerShell 5.1 -LiteralPath and -Leaf
        # sit in different parameter sets, so combining them fails to bind.
        $dir  = [IO.Path]::GetDirectoryName($Path)
        $leaf = [IO.Path]::GetFileName($Path)
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
            $made = "$Path.bak-$Stamp"
        }

        # Move-Item -Force, not [IO.File]::Replace: PowerShell binds $null
        # to the backup-path parameter as an empty string, which Replace
        # rejects. On one volume this is a single rename either way.
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        $replaced = $true

        # Rotation, only now that the file has been replaced. Pruning earlier
        # means a replace that fails (the file held open by something else,
        # say) still costs the oldest backup, and a few such failures in a row
        # would swap every intermediate copy for clones of one unchanged file.
        # The initial copy is never touched.
        $stamped = @(Get-ChildItem -LiteralPath $dir -Filter "$leaf.bak-2*" -ErrorAction SilentlyContinue |
                     Sort-Object Name)
        if ($stamped.Count -gt 2) {
            $stamped[0..($stamped.Count - 3)] | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        # Trim: .NET exception messages often end in a line break, which showed
        # up as a stray blank line under the warning.
        $reason = $_.Exception.Message.Trim()
        if ($_.Exception -is [System.IO.IOException]) {
            # Windows reports a replace blocked by a lock as "the file already
            # exists", which points nowhere useful.
            $reason += ' (is it open in another program?)'
        }
        Write-Warn "NOT PATCHED - $(Get-RelativePath $Path): $reason"
        return
    } finally {
        # finally, not catch: Ctrl+C skips catch but still runs this. After a
        # successful move there is nothing left at this path.
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        # A copy taken for a replace that never happened duplicates the live
        # file, so it is dropped rather than left to crowd out real history.
        # -Force also clears a read-only attribute, which the copy inherits.
        if ($made -and -not $replaced -and (Test-Path -LiteralPath $made)) {
            Remove-Item -LiteralPath $made -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Ok (Get-RelativePath $Path)
}

# -----------------------------------------------------------------------------
#  Uninstall
# -----------------------------------------------------------------------------
# Before anything else, including closing the browser: -UserOnly reaches a
# hive only administrators may write, and discovering that after Brave has
# been shut down helps nobody.
if ($UserOnly -and -not (Test-Admin)) {
    Stop-WithReason @(
        'HKCU\SOFTWARE\Policies is writable only by administrators, so'
        '-UserOnly needs an elevated session too.'
        ''
        'It is deliberately not auto-elevated: if you supplied a different'
        'admin account, the policies would land in that account''s hive'
        'rather than yours.'
    )
}

if ($Uninstall) {
    # No pre-elevation HKCU clean: Windows restricts HKCU\SOFTWARE\Policies
    # to administrators, so the unelevated process -- the only one that would
    # run such a block -- is refused outright. An earlier round added one on
    # review advice; it could never have worked.
    #
    # The consequence is that for a standard user who supplies a separate
    # admin's password, the elevated pass sees that admin's HKCU, not theirs.
    # Their own user-level policies have to be removed from their own elevated
    # session.
    if (-not $UserOnly -and -not (Test-Admin)) {
        Request-Elevation -Arguments @('-Uninstall')
    }

    Write-Head 'Removing policies'
    $targets = @($PolicyKey)
    if (-not $UserOnly) { $targets += 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave' }

    $total = 0
    $reported = $false
    foreach ($key in $targets) {
        if (-not (Test-Path $key)) { continue }

        # Counted per hive: a single total would hide which one was touched,
        # and a plain -Uninstall deliberately clears HKCU as well.
        $n = 0
        foreach ($name in (@($Policies.Keys) + $RetiredPolicies)) {
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
            if ($n -gt 0) {
                Write-Ok "$key - $n removed, key was left empty and deleted"
            } else {
                Write-Ok "$key - was already empty, removed"
            }
            $reported = $true
        } elseif ($n -gt 0) {
            $kept = @()
            if ($left.Count) { $kept += "$($left.Count) values" }
            if ($subs.Count) { $kept += "$($subs.Count) subkeys" }
            Write-Ok "$key - $n removed, $($kept -join ' and ') left untouched"
            $reported = $true
        }
    }
    # Only when nothing at all was said above: following "was already empty,
    # removed" with "none were present" reads as a contradiction.
    if ($total -eq 0 -and -not $reported) {
        Write-Warn 'none of this script''s policies were present'
    }
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
#  Quit Brave - it rewrites its preference files on exit
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
    $closedAny = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $procs = @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue |
                   Where-Object { $_.SessionId -eq $sessionId })
        if (-not $procs) { break }

        $windowed = @()
        foreach ($proc in $procs) {
            # The process can exit between Get-Process and here, and
            # $ErrorActionPreference = 'Stop' would make that fatal.
            try {
                $proc.Refresh()
                if ($proc.MainWindowHandle -ne 0) { $windowed += $proc }
            } catch { }
        }

        # Whatever is left has no window to close - background mode. Asking
        # again for the rest of the ten seconds achieves nothing.
        if (-not $windowed) { break }
        foreach ($proc in $windowed) {
            # CloseMainWindow returns false when the window will not take
            # WM_CLOSE - covered by a modal dialog, say - and throws if the
            # process has since exited. Either way nothing was closed.
            try {
                if ($proc.CloseMainWindow()) { $closedAny = $true }
            } catch { }
        }
        Start-Sleep -Milliseconds 300
    }

    # A window closing frees its handle before Brave finishes flushing
    # Preferences, so wait for the processes to actually go. Only worth doing
    # if a window was asked to close: a browser already sitting in the tray is
    # not going to exit on its own, and waiting on it buys nothing.
    #
    # Its own deadline, not the one above: if the last window closed near the
    # ten-second mark there would be no time left to flush, and the kill would
    # land mid-write - the very thing this wait exists to avoid.
    # $windowed is from the start of the last iteration, so ask again: a
    # window that refused to close (an unsaved-changes prompt, say) means the
    # loop timed out rather than finished, and waiting further is pointless.
    $stillWindowed = @(
        Get-Process -Name 'brave' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId } |
            Where-Object {
                try { $_.Refresh(); $_.MainWindowHandle -ne 0 } catch { $false }
            }
    )

    if ($closedAny -and -not $stillWindowed) {
        $flushBy = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $flushBy) {
            if (-not @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue |
                       Where-Object { $_.SessionId -eq $sessionId })) { break }
            Start-Sleep -Milliseconds 200
        }
    }

    $still = @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue |
               Where-Object { $_.SessionId -eq $sessionId })
    if ($still) {
        if ($stillWindowed) {
            Write-Warn 'a window would not close after 10s - forcing'
        } elseif ($closedAny) {
            Write-Warn 'still running after the windows closed - forcing'
        } else {
            # Nothing had a window: background mode (tray), where nothing short
            # of a kill will do. Brave shows a "did not shut down correctly" bar.
            Write-Warn 'no window to close (background mode) - forcing'
        }
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
foreach ($name in $RetiredPolicies) {
    Remove-ItemProperty -Path $PolicyKey -Name $name -Force -ErrorAction SilentlyContinue
}
Write-Ok "$($Policies.Count) policies written to $PolicyKey"
if ($UserOnly) { Write-Warn 'user-level policies; machine-wide ones override these if present' }
Write-Host ''

# -----------------------------------------------------------------------------
#  2. Profile preferences - toolbar buttons and other non-policy toggles
# -----------------------------------------------------------------------------
if ($BraveAlive) {
    # Already warned above: Brave is still running and would overwrite this.
} elseif (-not (Test-Path -LiteralPath $DataDir)) {
    Write-Warn 'Brave profile not found - skipping profile preferences'
} else {
    Write-Head 'Patching profile preferences (backups alongside each file)'

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
if ($PSCommandPath) {
    Write-Host '  Revert:  .\brave-debloat.ps1 -Uninstall'
} else {
    # Piped in: there is no file on disk to call.
    Write-Host '  Revert:  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/vladtvoeit/brave-debloat/main/windows/brave-debloat.ps1))) -Uninstall'
}
