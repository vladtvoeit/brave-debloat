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
# TMPDIR on macOS ends in a slash, which would otherwise appear doubled in
# the path printed to the user.
PROFILE_OUT="${TMPDIR:-/tmp}"
PROFILE_OUT="${PROFILE_OUT%/}/brave-debloat.mobileconfig"
TS="$(date +%Y%m%d-%H%M%S)"
BRAVE_ALIVE=0
# current | queued | skipped. `open` on the profile returns immediately, long
# before anyone has clicked Install, so the closing text cannot ask the system
# whether it is installed and expect a useful answer.
PROFILE_STATE=skipped
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
# No pipe into grep: grep -q exits at the first match, the producer takes
# SIGPIPE, and pipefail reports that as failure. Documented as a trap and then
# reintroduced here anyway, so it now lives in one function used by both
# callers.
profile_installed() {
  local out
  out="$(system_profiler SPConfigurationProfileDataType 2>/dev/null)" || return 1
  case "$out" in
    *com.local.brave-debloat*) return 0 ;;
    *) return 1 ;;
  esac
}

profile_is_current() {
  # The plist in /Library/Managed Preferences is merged from every installed
  # profile, so comparing against it exactly would call ours out of date on a
  # Mac that has any other profile touching com.brave.Browser. Compare the key
  # set of our own payload instead, and the effective values from the plist.
  [ -f "$MANAGED" ] || return 1

  local sp
  sp="$(system_profiler SPConfigurationProfileDataType -json 2>/dev/null)" || return 1

  # The payload is passed as an argument rather than through a temp file, so
  # there is nothing to clean up if this is interrupted.
  python3 - "$sp" "$MANAGED" "${POLICIES[@]}" <<'PY'
import json, plistlib, re, sys

payload, managed = sys.argv[1], sys.argv[2]
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


try:
    parsed = json.loads(payload)
except ValueError:
    sys.exit(1)

installed = set()
for profile in profiles(parsed):
    for item in profile.get("_items", []):
        blob = item.get("spconfigprofile_payload_data", "")
        installed |= set(re.findall(r'^\s*"?([A-Za-z][A-Za-z0-9_]*)"?\s*=\s*', blob, re.M))
installed -= {"PayloadContent", "Forced", "mcx_preference_settings"}

if not installed or installed != set(expected):
    sys.exit(1)

try:
    with open(managed, "rb") as handle:
        live = plistlib.load(handle)
except Exception:
    # Unreadable or corrupt: treat as "not current" and regenerate rather
    # than dumping a traceback into the user's terminal.
    sys.exit(1)
for key, want in expected.items():
    got = live.get(key)
    if type(got) is not type(want) or got != want:
        sys.exit(1)
sys.exit(0)
PY
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

# Policies this script used to set and Chromium has since removed. A removed
# policy shows as Error in brave://policy, so it is cleaned out of the user
# domain on every run and on --uninstall. The profile needs no help: it is
# regenerated from POLICIES, and the old one no longer counts as current.
RETIRED_POLICY_NAMES=(
  "SafeBrowsingExtendedReportingEnabled" # unsupported after M144
)

# -----------------------------------------------------------------------------
#  Uninstall
# -----------------------------------------------------------------------------
if [ "$WANT_UNINSTALL" = "1" ]; then
  bold "==> Removing user-domain policy keys"
  removed=0
  for entry in "${POLICIES[@]}" "${RETIRED_POLICY_NAMES[@]}"; do
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
  bold "==> Configuration profile"
  if profile_installed; then
    echo "   Remove it by hand: System Settings → General → Device Management"
    echo "   → \"Brave Debloat\" → remove."
    open "x-apple.systempreferences:com.apple.Profiles-Settings.extension" 2>/dev/null || true
  else
    warn "not installed"
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
  PROFILE_STATE=current
  bold "==> Configuration profile"
  ok "already installed and up to date — skipping"
  echo

elif [ "$WANT_PROFILE" = "1" ]; then
  PROFILE_STATE=queued
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
        *) echo "unknown policy type: $t" >&2; exit 1 ;;
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
#  precedence. This does NOT substitute for it: every Brave policy declares
#  can_be_recommended false, so Rewards, Wallet, Leo and News ignore values
#  that arrive this way. Only upstream Chromium policies honour them.
# -----------------------------------------------------------------------------
bold "==> Writing user-domain defaults"
for entry in "${POLICIES[@]}"; do
  IFS='|' read -r k t v <<< "$entry"
  case "$t" in
    bool)    defaults write "$DOMAIN" "$k" -bool "$v" ;;
    integer) defaults write "$DOMAIN" "$k" -int "$v" ;;
    *) echo "unknown policy type: $t" >&2; exit 1 ;;
  esac
done
for k in "${RETIRED_POLICY_NAMES[@]}"; do
  defaults delete "$DOMAIN" "$k" 2>/dev/null || true
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
  bold "==> Patching profile preferences (backups alongside each file)"
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


def remove(path):
    """Delete a file this script made, even if it carries the immutable flag.

    shutil.copy2 copies a file's flags along with its contents, so a backup of
    an immutable Preferences is itself immutable and a plain unlink of it
    fails. People do set that flag on purpose, to stop Brave resetting their
    settings; without this, every failed run would leave behind a copy that
    can neither be pruned nor cleaned up."""
    try:
        os.unlink(path)
    except PermissionError:
        try:
            os.chflags(path, 0)
            os.unlink(path)
        except (AttributeError, OSError):
            pass
    except OSError:
        pass


def make_backups(path):
    """Keep the untouched original forever, and take this run's copy.

    Returns the timestamped copy it made, or None on a first run, where the
    initial copy is this same file and a second identical one would be noise.

    Preferences runs to megabytes and the README tells people to re-run after
    Brave updates, so without rotation the profile directory fills up with
    copies of already-patched state -- and the one worth having, from before
    the first run, is the one that scrolls away. Rotation is prune_backups(),
    kept apart so that it can wait until the replace has actually happened."""
    # glob.escape: a profile path may contain [ or ], which glob would
    # otherwise read as a character class and match nothing.
    stamped = sorted(glob.glob(glob.escape(path) + ".bak-2*"))
    initial = f"{path}.bak-initial"

    first_ever = not stamped and not os.path.exists(initial)
    if not os.path.exists(initial):
        shutil.copy2(stamped[0] if stamped else path, initial)
    if first_ever:
        return None

    made = f"{path}.bak-{ts}"
    shutil.copy2(path, made)
    return made


def prune_backups(path):
    """Keep the two most recent timestamped copies; the initial one is never
    touched. Only call this once the file has been replaced: pruning earlier
    means a replace that fails still costs the oldest backup, and a few such
    failures in a row would swap every intermediate copy for clones of the
    same unchanged file."""
    for stale in sorted(glob.glob(glob.escape(path) + ".bak-2*"))[:-2]:
        remove(stale)


def patch(path, prefs):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as exc:
        print(f"   ! skipped {os.path.relpath(path, data)}: {exc}")
        return
    tmp = f"{path}.tmp-{ts}"
    made = None
    replaced = False
    try:
        for key, value in prefs.items():
            deep_set(doc, key, value)
        # Write-then-rename: open(path, "w") truncates immediately, so a
        # failure mid-serialisation would leave an empty Preferences file.
        #
        # 0600 from the moment it exists: until the rename this file holds the
        # whole of Preferences, and the default umask would leave that
        # readable by every local account.
        handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with open(handle, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)
        # The copy of the current file has to be taken before it is replaced,
        # but nothing is deleted until after: see prune_backups().
        made = make_backups(path)
        # Match the original exactly, in case Brave used something other
        # than 0600; os.replace carries the temp file's mode across.
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
        replaced = True
        prune_backups(path)
    except Exception as exc:
        print(f"   ! NOT PATCHED {os.path.relpath(path, data)}: {exc}")
        return
    finally:
        # finally, not except: Ctrl+C raises KeyboardInterrupt, which is not
        # an Exception and would otherwise leave the temp file behind. After a
        # successful replace there is nothing at this path to remove.
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        # A copy taken for a replace that never happened duplicates the live
        # file, so it is dropped rather than left to crowd out real history.
        if made and not replaced and os.path.exists(made):
            remove(made)
    print(f"   \033[32m✔\033[0m {os.path.relpath(path, data)}")


# glob.escape on the base: a redirected HOME in a test harness, or any home
# directory with [ or ] in it, would otherwise match nothing here and never
# reach the escaping already done further down.
base = glob.escape(data)
for profile in glob.glob(os.path.join(base, "Default", "Preferences")) + \
               sorted(glob.glob(os.path.join(base, "Profile *", "Preferences"))):
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
case "$PROFILE_STATE" in
  current)
    echo "  Verify:  brave://policy    — every policy listed, status OK"
    echo "           brave://settings  — Rewards / Wallet / VPN / Leo are gone"
    ;;
  queued)
    echo "  Once the profile is installed, verify:"
    echo "           brave://policy    — every policy listed, status OK"
    echo "           brave://settings  — Rewards / Wallet / VPN / Leo are gone"
    ;;
  *)
    if profile_is_current; then
      echo "  Verify:  brave://policy    — every policy listed, status OK"
      echo "           brave://settings  — Rewards / Wallet / VPN / Leo are gone"
    elif profile_installed; then
      # Installed but not matching: --no-profile left it alone, so what is in
      # effect is the old set of policies, not the one just written.
      warn "the installed configuration profile is out of date"
      echo "     Re-run without --no-profile to rebuild and reinstall it."
    else
      # Without the profile the Brave policies do not apply at all, so
      # promising that brave://policy looks clean would be a lie.
      warn "no configuration profile is installed, so the policies are not in effect"
      echo "     Brave's own policies refuse the recommended level that the"
      echo "     user-domain fallback can offer, so Rewards, Wallet, Leo and"
      echo "     News stay on until the profile is installed."
    fi
    ;;
esac
echo
if [ -n "$SELF" ]; then
  echo "  Revert:  ./$SELF_NAME --uninstall"
else
  echo "  Revert:  curl -fsSL $REPO/macos/brave-debloat.sh | bash -s -- --uninstall"
fi
