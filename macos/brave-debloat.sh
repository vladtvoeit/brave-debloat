#!/usr/bin/env bash
# =============================================================================
#  brave-debloat for macOS
#
#  Disables Brave Rewards/BAT, Wallet, VPN upsell, Leo AI, News, Talk,
#  Playlist, Speedreader, Wayback Machine, Tor, IPFS, and telemetry
#  (P3A, daily usage ping, Web Discovery, crash reports, promo tabs).
#
#  Usage:
#     ./brave-debloat.sh                  apply everything
#     ./brave-debloat.sh --no-profile     skip the configuration profile
#     ./brave-debloat.sh --sponsored      also disable sponsored (ad) wallpapers
#     ./brave-debloat.sh --uninstall      revert what this script set
#
#  Shields and auto-updates are never touched.
# =============================================================================

set -euo pipefail

# Running as root would leave Preferences owned by root (copymode copies the
# mode, not the owner), and send `defaults write` to /var/root. Neither is
# recoverable without noticing first.
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not with sudo." >&2
  echo "Nothing here needs root; the profile is installed from System Settings." >&2
  exit 1
fi

DOMAIN="com.brave.Browser"
APP="Brave Browser"
DATA="$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
MANAGED="/Library/Managed Preferences/com.brave.Browser.plist"
PROFILE_OUT="${TMPDIR:-/tmp}/brave-debloat.mobileconfig"
TS="$(date +%Y%m%d-%H%M%S)"
BRAVE_ALIVE=0
REPO="https://raw.githubusercontent.com/vladtvoeit/brave-debloat/main"

WANT_PROFILE=1
WANT_SPONSORED=0
WANT_UNINSTALL=0

# When piped (curl … | bash) $0 is "bash" and has no readable source, so fall
# back to the project name for anything user-facing.
if [ -r "$0" ] && [ "${0##*/}" != "bash" ]; then
  SELF="$0"
else
  SELF=""
fi
SELF_NAME="${SELF:+${SELF##*/}}"
SELF_NAME="${SELF_NAME:-brave-debloat.sh}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-profile) WANT_PROFILE=0 ;;
    --sponsored)  WANT_SPONSORED=1 ;;
    --uninstall)  WANT_UNINSTALL=1 ;;
    -h|--help)
      if [ -n "$SELF" ]; then
        sed -n '3,/^# =\{10,\}/p' "$SELF" | sed 's/^# \{0,1\}//; /^=\{10,\}/d'
      else
        echo "brave-debloat — see https://github.com/vladtvoeit/brave-debloat"
        echo "Options: --no-profile  --sponsored  --uninstall"
      fi
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m✔\033[0m %s\n' "$1"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$1"; }

# True only if macOS has already materialised every expected policy from an
# installed profile, with matching values.
profile_is_current() {
  # The plist in /Library/Managed Preferences is merged from every installed
  # profile, so comparing against it exactly would call ours out of date on a
  # Mac that has any other profile touching com.brave.Browser. Compare the key
  # set of our own payload instead, and the effective values from the plist.
  [ -f "$MANAGED" ] || return 1

  local spfile livefile rc
  spfile="$(mktemp)"; livefile="$(mktemp)"
  if ! system_profiler SPConfigurationProfileDataType -json >"$spfile" 2>/dev/null \
     || ! plutil -convert json -o - "$MANAGED" >"$livefile" 2>/dev/null; then
    rm -f "$spfile" "$livefile"
    return 1
  fi

  python3 -c '
import json, re, sys

payload_path, live_path = sys.argv[1], sys.argv[2]
expected = {}
for entry in sys.argv[3:]:
    key, kind, raw = entry.split("|")
    expected[key] = raw == "true" if kind == "bool" else int(raw)


def profiles(node):
    if isinstance(node, dict):
        if node.get("spconfigprofile_profile_identifier") == "com.local.brave-debloat":
            yield node
        for value in node.values():
            yield from profiles(value)
    elif isinstance(node, list):
        for value in node:
            yield from profiles(value)


installed = set()
for profile in profiles(json.load(open(payload_path))):
    for item in profile.get("_items", []):
        blob = item.get("spconfigprofile_payload_data", "")
        installed |= set(re.findall(r"^\s*\"?([A-Za-z][A-Za-z0-9]*)\"?\s*=\s*", blob, re.M))
installed -= {"PayloadContent", "Forced", "mcx_preference_settings"}

if not installed or installed != set(expected):
    sys.exit(1)

live = json.load(open(live_path))
for key, want in expected.items():
    got = live.get(key)
    if type(got) is not type(want) or got != want:
        sys.exit(1)
sys.exit(0)
' "$spfile" "$livefile" "${POLICIES[@]}"
  rc=$?
  rm -f "$spfile" "$livefile"
  return $rc
}

# -----------------------------------------------------------------------------
#  Policy set. Format: Name|type|value   (type: bool | integer)
# -----------------------------------------------------------------------------
POLICIES=(
  # Crypto, ads, upsells
  "BraveRewardsDisabled|bool|true"
  "BraveWalletDisabled|bool|true"
  "BraveVPNDisabled|bool|true"
  "BraveAIChatEnabled|bool|false"
  "BraveLocalAIEnabled|bool|false"        # on-device AI, downloads a model
  "BraveNewsDisabled|bool|true"
  "BraveTalkDisabled|bool|true"
  "BravePlaylistEnabled|bool|false"
  "BraveSpeedreaderEnabled|bool|false"
  "BraveWaybackMachineEnabled|bool|false"
  "TorDisabled|bool|true"
  "IPFSEnabled|bool|false"

  # Brave telemetry
  "BraveP3AEnabled|bool|false"
  "BraveStatsPingEnabled|bool|false"
  "BraveWebDiscoveryEnabled|bool|false"

  # Chromium telemetry and promos
  "MetricsReportingEnabled|bool|false"
  "SafeBrowsingExtendedReportingEnabled|bool|false"
  "UrlKeyedAnonymizedDataCollectionEnabled|bool|false"
  "FeedbackSurveysEnabled|bool|false"
  "PromotionalTabsEnabled|bool|false"

  # Privacy Sandbox — Chromium's own ad-targeting stack
  "PrivacySandboxAdMeasurementEnabled|bool|false"
  "PrivacySandboxPromptEnabled|bool|false"
  "PrivacySandboxSiteEnabledAdsEnabled|bool|false"

  # Behaviour
  "BackgroundModeEnabled|bool|false"
  "DefaultBrowserSettingEnabled|bool|false"
  "SpellCheckServiceEnabled|bool|false"
  "NetworkPredictionOptions|integer|2"
)

# -----------------------------------------------------------------------------
#  Uninstall
# -----------------------------------------------------------------------------
if [ "$WANT_UNINSTALL" = "1" ]; then
  bold "==> Removing user-domain policy keys"
  removed=0
  for entry in "${POLICIES[@]}"; do
    IFS='|' read -r k _ _ <<< "$entry"
    if defaults delete "$DOMAIN" "$k" 2>/dev/null; then
      removed=$((removed + 1))
    fi
  done
  if [ "$removed" -eq 0 ]; then
    warn "none of this script's policies were present"
  else
    ok "$removed keys removed"
  fi
  echo
  bold "Configuration profile"
  echo "   Remove it by hand: System Settings → General → Device Management"
  echo "   → \"Brave Debloat\" → remove."
  if system_profiler SPConfigurationProfileDataType 2>/dev/null \
     | grep -q "com.local.brave-debloat"; then
    open "x-apple.systempreferences:com.apple.Profiles-Settings.extension" 2>/dev/null || true
  fi
  echo
  echo "   Profile preferences are not reverted automatically."
  echo "   Restore *.bak-initial next to Preferences / Local State for the"
  echo "   state from before this script first ran, or a *.bak-<timestamp> copy."
  exit 0
fi

# -----------------------------------------------------------------------------
#  Quit Brave — it rewrites its preference files on exit
# -----------------------------------------------------------------------------
if pgrep -u "$(id -u)" -x "$APP" >/dev/null 2>&1; then
  bold "==> Quitting $APP"
  osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true

  # Brave flushes Preferences on exit; killing it mid-write is how profiles
  # get corrupted. Give it up to 10s, force only if it hangs.
  waited=0
  while pgrep -u "$(id -u)" -x "$APP" >/dev/null 2>&1 && [ "$waited" -lt 50 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  if pgrep -u "$(id -u)" -x "$APP" >/dev/null 2>&1; then
    warn "still running after 10s — forcing"
    pkill -u "$(id -u)" -x "$APP" >/dev/null 2>&1 || true
    sleep 2
  fi
  if pgrep -u "$(id -u)" -x "$APP" >/dev/null 2>&1; then
    BRAVE_ALIVE=1
    warn "could not quit $APP — profile preferences will be skipped,"
    warn "it would overwrite them on exit. Policies still apply."
  fi
fi

# -----------------------------------------------------------------------------
#  1. Configuration profile — the durable layer
#
#  Do NOT write into /Library/Managed Preferences directly. That directory is
#  generated by macOS from installed configuration profiles; a hand-written
#  file there is treated as stray and deleted, typically at the next reboot.
# -----------------------------------------------------------------------------
if [ "$WANT_PROFILE" = "1" ] && profile_is_current; then
  bold "==> Configuration profile"
  ok "already installed and up to date — skipping"
  echo

elif [ "$WANT_PROFILE" = "1" ]; then
  bold "==> Building configuration profile"

  {
    cat <<'HEAD'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadType</key><string>Configuration</string>
	<key>PayloadVersion</key><integer>1</integer>
	<key>PayloadIdentifier</key><string>com.local.brave-debloat</string>
	<key>PayloadDisplayName</key><string>Brave Debloat</string>
	<key>PayloadDescription</key><string>Disables Rewards, Wallet, VPN, Leo AI, News, Talk, Tor, IPFS and telemetry in Brave Browser.</string>
	<key>PayloadScope</key><string>System</string>
	<key>PayloadRemovalDisallowed</key><false/>
HEAD
    echo "	<key>PayloadUUID</key><string>$(uuidgen)</string>"
    cat <<'MID'
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>
			<key>PayloadVersion</key><integer>1</integer>
			<key>PayloadIdentifier</key><string>com.local.brave-debloat.prefs</string>
			<key>PayloadDisplayName</key><string>Brave Browser Policies</string>
MID
    echo "			<key>PayloadUUID</key><string>$(uuidgen)</string>"
    cat <<'MID2'
			<key>PayloadContent</key>
			<dict>
				<key>com.brave.Browser</key>
				<dict>
					<key>Forced</key>
					<array>
						<dict>
							<key>mcx_preference_settings</key>
							<dict>
MID2
    for entry in "${POLICIES[@]}"; do
      IFS='|' read -r k t v <<< "$entry"
      printf '\t\t\t\t\t\t\t\t<key>%s</key>' "$k"
      case "$t" in
        bool)    [ "$v" = "true" ] && printf '<true/>\n' || printf '<false/>\n' ;;
        integer) printf '<integer>%s</integer>\n' "$v" ;;
      esac
    done
    cat <<'TAIL'
							</dict>
						</dict>
					</array>
				</dict>
			</dict>
		</dict>
	</array>
</dict>
</plist>
TAIL
  } > "$PROFILE_OUT"

  plutil -lint "$PROFILE_OUT" >/dev/null
  ok "${#POLICIES[@]} policies written to $PROFILE_OUT"

  echo
  bold "==> ACTION NEEDED: install the profile"
  echo "   macOS does not allow installing profiles from the command line,"
  echo "   so this last step is manual and takes two clicks:"
  echo
  echo "     System Settings opens → Review → Install → admin password"
  echo
  echo "   If the window does not appear, look under"
  echo "   System Settings → General → Device Management → Downloaded Profile."
  echo
  open "$PROFILE_OUT" || warn "could not open $PROFILE_OUT — open it manually"
  # Queuing the profile only raises a notification banner, which is invisible
  # under Do Not Disturb; this puts the right pane on screen.
  open "x-apple.systempreferences:com.apple.Profiles-Settings.extension" 2>/dev/null || true
  echo
fi

# -----------------------------------------------------------------------------
#  2. User-domain defaults — fallback layer, no admin rights needed
#
#  Read by Brave as recommended-level policy. The profile above takes
#  precedence; this keeps most settings in place if the profile is removed.
# -----------------------------------------------------------------------------
bold "==> Writing user-domain defaults"
for entry in "${POLICIES[@]}"; do
  IFS='|' read -r k t v <<< "$entry"
  case "$t" in
    bool)    defaults write "$DOMAIN" "$k" -bool "$v" ;;
    integer) defaults write "$DOMAIN" "$k" -int "$v" ;;
  esac
done
ok "${#POLICIES[@]} keys written to $DOMAIN"
echo

# -----------------------------------------------------------------------------
#  3. Profile preferences — toolbar buttons and other non-policy toggles
#
#  Needs Full Disk Access: macOS protects browser profile directories, so
#  reading these files fails with EPERM for any app without that grant.
# -----------------------------------------------------------------------------
if [ "$BRAVE_ALIVE" = "1" ]; then
  :
elif [ ! -d "$DATA" ]; then
  warn "Brave profile not found — skipping profile preferences"
elif ! ls "$DATA" >/dev/null 2>&1; then
  bold "==> Profile preferences"
  warn "no access to $DATA"
  echo "     macOS protects browser profile folders. Grant Full Disk Access to"
  echo "     the app running this script (Terminal, iTerm, …), then re-run:"
  echo
  echo "       System Settings → Privacy & Security → Full Disk Access"
  echo
  echo "     Policies above still apply — this only affects toolbar buttons"
  echo "     and a few toggles that have no policy equivalent."
else
  bold "==> Patching profile preferences (backups: *.bak-$TS)"
  python3 - "$DATA" "$TS" "$WANT_SPONSORED" <<'PY'
import glob, json, os, shutil, sys

data, ts, sponsored = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

PROFILE = {
    # Every name here is verified against brave-core. A wrong one is silent:
    # Chromium stores only prefs that differ from their default, so an
    # invented key and an untouched real key look identical on disk.
    "brave.new_tab_page.show_brave_news": False,
    "brave.today.opted_in": False,
    "brave.today.should_show_toolbar_button": False,
    "brave.rewards.show_brave_rewards_button_in_location_bar": False,
    "brave.rewards.enabled": False,
    "brave.wallet.show_wallet_icon_on_toolbar": False,
    "brave.brave_vpn.show_button": False,
    "brave.new_tab_page.show_rewards": False,
    "brave.new_tab_page.show_brave_vpn": False,
    "brave.new_tab_page.show_together": False,
    "brave.ai_chat.show_toolbar_button": False,
    "brave.ai_chat.autocomplete_provider_enabled": False,
    "brave.playlist.enabled": False,
    "brave.web_discovery_enabled": False,
    "browser.check_default_browser": False,  # upstream Chromium pref
}

# Opt-in. Sponsored wallpapers are ads; Brave's own stock photos are left
# alone — those are brave.new_tab_page.show_background_image, never written.
if sponsored:
    PROFILE.update({
        "brave.brave_ads.sponsored.enabled": False,
        # Retired in 08/2026 but still migrated into the pref above, so it
        # keeps older builds covered.
        "brave.new_tab_page.show_branded_background_image": False,
        "brave.branded_wallpaper_notification_dismissed": True,
    })

LOCAL_STATE = {
    "brave.p3a.enabled": False,
    "brave.p3a.notice_acknowledged": True,
    "brave.stats.reporting_enabled": False,
}


def deep_set(doc, dotted, value):
    keys = dotted.split(".")
    cur = doc
    for k in keys[:-1]:
        if not isinstance(cur.get(k), dict):
            cur[k] = {}
        cur = cur[k]
    cur[keys[-1]] = value


def keep_backups(path):
    """Keep the untouched original forever, plus the two most recent copies.

    Preferences runs to megabytes and the README tells people to re-run after
    Brave updates, so without this the profile directory fills up with copies
    of already-patched state — and the one worth having, from before the first
    run, is the one that scrolls away."""
    # glob.escape: a profile path may contain [ or ], which glob would
    # otherwise read as a character class and match nothing.
    pattern = glob.escape(path) + ".bak-2*"
    stamped = sorted(glob.glob(pattern))
    initial = f"{path}.bak-initial"

    first_ever = not stamped and not os.path.exists(initial)
    if not os.path.exists(initial):
        shutil.copy2(stamped[0] if stamped else path, initial)

    # On a first run the initial copy is this same file; a second identical
    # one would be noise.
    if not first_ever:
        shutil.copy2(path, f"{path}.bak-{ts}")

    for stale in sorted(glob.glob(pattern))[:-2]:
        try:
            os.unlink(stale)
        except OSError:
            pass


def patch(path, prefs):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as exc:
        print(f"   ! skipped {os.path.relpath(path, data)}: {exc}")
        return
    tmp = f"{path}.tmp-{ts}"
    try:
        for key, value in prefs.items():
            deep_set(doc, key, value)
        # Write-then-rename: open(path, "w") truncates immediately, so a
        # failure mid-serialisation would leave an empty Preferences file.
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)
        # Only now that the replacement exists on disk is it safe to touch the
        # backups. Rotating first meant two failed runs in a row could discard
        # both surviving copies while writing nothing.
        keep_backups(path)
        # os.replace carries the temp file's mode across, and under the usual
        # umask that would turn Brave's 0600 into a world-readable 0644.
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except Exception as exc:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        print(f"   ! skipped {os.path.relpath(path, data)}: {exc}")
        return
    print(f"   \033[32m✔\033[0m {os.path.relpath(path, data)}")


for profile in glob.glob(os.path.join(data, "Default", "Preferences")) + \
               glob.glob(os.path.join(data, "Profile *", "Preferences")):
    patch(profile, PROFILE)

local_state = os.path.join(data, "Local State")
if os.path.exists(local_state):
    patch(local_state, LOCAL_STATE)
PY

  # "sponsored-images" is a chrome:// URL path inside Brave, not a directory,
  # so only ads_service is ever present — and usually it is not.
  cleared=0
  for pdir in "$DATA"/Default "$DATA"/Profile\ *; do
    [ -d "$pdir/ads_service" ] || continue
    rm -rf "$pdir/ads_service" 2>/dev/null && cleared=$((cleared + 1))
  done
  if [ "$cleared" -gt 0 ]; then
    ok "ad cache cleared ($cleared)"
  fi
fi

# -----------------------------------------------------------------------------
echo
bold "Done. Restart Brave."
echo
echo "  Verify:  brave://policy    — every policy listed, status OK"
echo "           brave://settings  — Rewards / Wallet / VPN / Leo are gone"
echo
if [ -n "$SELF" ]; then
  echo "  Revert:  $SELF_NAME --uninstall"
else
  echo "  Revert:  curl -fsSL $REPO/macos/brave-debloat.sh | bash -s -- --uninstall"
fi
