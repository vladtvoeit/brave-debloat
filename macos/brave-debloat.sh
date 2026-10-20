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

DOMAIN="com.brave.Browser"
APP="Brave Browser"
DATA="$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
MANAGED="/Library/Managed Preferences/com.brave.Browser.plist"
PROFILE_OUT="${TMPDIR:-/tmp}/brave-debloat.mobileconfig"
TS="$(date +%Y%m%d-%H%M%S)"

WANT_PROFILE=1
WANT_SPONSORED=0
WANT_UNINSTALL=0

# When piped (curl … | bash) $0 is "bash" and has no readable source, so fall
# back to the project name for anything user-facing.
if [ -r "$0" ] && [ "$(basename "$0")" != "bash" ]; then
  SELF="$0"
else
  SELF=""
fi
SELF_NAME="${SELF:+$(basename "$SELF")}"
SELF_NAME="${SELF_NAME:-brave-debloat.sh}"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-profile) WANT_PROFILE=0 ;;
    --sponsored)  WANT_SPONSORED=1 ;;
    --uninstall)  WANT_UNINSTALL=1 ;;
    -h|--help)
      if [ -n "$SELF" ]; then
        sed -n '2,18p' "$SELF" | sed 's/^# \{0,1\}//; /^=\{10,\}$/d'
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
  [ -f "$MANAGED" ] || return 1
  plutil -convert json -o - "$MANAGED" 2>/dev/null | python3 -c '
import json, sys
try:
    live = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for entry in sys.argv[1:]:
    key, kind, raw = entry.split("|")
    want = raw == "true" if kind == "bool" else int(raw)
    if live.get(key) != want:
        sys.exit(1)
sys.exit(0)
' "${POLICIES[@]}"
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
  for entry in "${POLICIES[@]}"; do
    IFS='|' read -r k _ _ <<< "$entry"
    defaults delete "$DOMAIN" "$k" 2>/dev/null && ok "$k" || true
  done
  echo
  bold "Configuration profile"
  echo "   Remove it by hand: System Settings → General → Device Management"
  echo "   → \"Brave Debloat\" → remove."
  echo
  echo "   Profile preferences are not reverted automatically."
  echo "   Restore a *.bak-* file next to Preferences / Local State if needed."
  exit 0
fi

# -----------------------------------------------------------------------------
#  Quit Brave — it rewrites its preference files on exit
# -----------------------------------------------------------------------------
bold "==> Quitting $APP"
osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
sleep 2
pkill -x "$APP" >/dev/null 2>&1 || true
sleep 1

# -----------------------------------------------------------------------------
#  1. Configuration profile — the durable layer
#
#  Do NOT write into /Library/Managed Preferences directly. That directory is
#  generated by macOS from installed configuration profiles; a hand-written
#  file there is treated as stray and deleted, typically at the next reboot.
# -----------------------------------------------------------------------------
if [ "$WANT_PROFILE" = "1" ]; then
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

  if profile_is_current; then
    ok "profile already installed and up to date — skipping"
  else
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
  fi
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
if [ ! -d "$DATA" ]; then
  warn "Brave profile not found — skipping profile preferences"
elif ! head -c 1 "$DATA/Local State" >/dev/null 2>&1; then
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
    "brave.new_tab_page.show_brave_today": False,
    "brave.new_tab_page.show_brave_news": False,
    "brave.today.enabled": False,
    "browser.check_default_browser": False,
    "brave.rewards.show_brave_rewards_button": False,
    "brave.rewards.show_button": False,
    "brave.wallet.show_wallet_icon_on_toolbar": False,
    "brave.vpn.show_button": False,
    "brave.ai_chat.enabled_by_user": False,
    "brave.ai_chat.autocomplete_provider_enabled": False,
    "brave.playlist.enabled": False,
    "brave.speedreader.enabled": False,
    "brave.wayback_machine_enabled": False,
    "ipfs.ipfs_enabled": False,
    "brave.p3a.enabled": False,
    "brave.stats.ping_enabled": False,
}

# Opt-in: these cover sponsored (ad) wallpapers only. Brave's own stock
# photos are controlled by show_background_image, which is never touched.
if sponsored:
    PROFILE.update({
        "brave.new_tab_page.show_sponsored_images": False,
        "brave.new_tab_page.show_branded_wallpaper": False,
        "brave.new_tab_page.branded_wallpaper_notification": False,
    })

LOCAL_STATE = {
    "brave.p3a.enabled": False,
    "brave.p3a.notice_acknowledged": True,
    "brave.stats.ping_enabled": False,
    "brave.rewards.enabled": False,
    "brave.web_discovery.enabled": False,
}


def deep_set(doc, dotted, value):
    keys = dotted.split(".")
    cur = doc
    for k in keys[:-1]:
        if not isinstance(cur.get(k), dict):
            cur[k] = {}
        cur = cur[k]
    cur[keys[-1]] = value


def patch(path, prefs):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as exc:
        print(f"   ! skipped {os.path.basename(path)}: {exc}")
        return
    try:
        shutil.copy2(path, f"{path}.bak-{ts}")
        for key, value in prefs.items():
            deep_set(doc, key, value)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)
    except Exception as exc:
        print(f"   ! skipped {os.path.basename(path)}: {exc}")
        return
    print(f"   \033[32m✔\033[0m {os.path.relpath(path, data)}")


for profile in glob.glob(os.path.join(data, "Default", "Preferences")) + \
               glob.glob(os.path.join(data, "Profile *", "Preferences")):
    patch(profile, PROFILE)

local_state = os.path.join(data, "Local State")
if os.path.exists(local_state):
    patch(local_state, LOCAL_STATE)
PY

  rm -rf "$DATA/Default/ads_service" 2>/dev/null || true
  rm -rf "$DATA/sponsored-images" "$DATA/Default/sponsored-images" 2>/dev/null || true
  ok "ad cache cleared"
fi

# -----------------------------------------------------------------------------
echo
bold "Done. Restart Brave."
echo
echo "  Verify:  brave://policy    — every policy listed, status OK"
echo "           brave://settings  — Rewards / Wallet / VPN / Leo are gone"
echo
echo "  Revert:  $SELF_NAME --uninstall"
