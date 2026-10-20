#!/usr/bin/env bash
# Run every check this project has that can run on this machine.
#
#   tools/check.sh
#
# Exit status is non-zero if anything failed. A check that cannot run is
# reported as SKIP, with the reason, and says so out loud: a check that quietly
# does not run reads exactly like one that passed, which is the failure this
# project keeps running into. CI covers shellcheck and PowerShell parsing; it
# does not run the macOS smoke run.
#
# Needs network: verify-keys.py reads brave-core.

set -u
cd "$(dirname "$0")/.." || exit 2

# Keep review runs from leaving __pycache__ behind in the working tree.
export PYTHONDONTWRITEBYTECODE=1

failed=0

pass() { printf '  ok    %s\n' "$1"; }
skip() { printf '  SKIP  %s  (%s)\n' "$1" "$2"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          /'
  failed=1
}

# run <name> <command...>
run() {
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then pass "$name"; else fail "$name" "$out"; fi
}

# Both scripts are covered by the same lists here as in CI.
shell_scripts=(macos/brave-debloat.sh tools/check.sh)

# bash -n parses only the first file it is given and treats the rest as
# arguments to that script, so each one is checked on its own.
#
# Called through run() below, which shellcheck cannot see. Newer versions say so
# once per function (SC2329); older ones (the CI runner's) flag every line of the
# body as unreachable (SC2317). Both codes are disabled for the three functions
# that are invoked this way.
# shellcheck disable=SC2317,SC2329
bash_syntax() {
  local script
  for script in "${shell_scripts[@]}"; do
    bash -n "$script" || {
      echo "in $script"
      return 1
    }
  done
}

echo "brave-debloat checks"

run "bash syntax" bash_syntax

if command -v shellcheck >/dev/null 2>&1; then
  run "shellcheck" shellcheck "${shell_scripts[@]}"
else
  skip "shellcheck" "shellcheck not installed; CI runs it"
fi

if command -v pwsh >/dev/null 2>&1; then
  # The single quotes are deliberate: this is PowerShell, and bash must not
  # expand any of it.
  # shellcheck disable=SC2016
  run "PowerShell syntax" pwsh -NoProfile -Command '
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      (Resolve-Path windows/brave-debloat.ps1), [ref]$null, [ref]$e) | Out-Null
    if ($e) { $e | % { "line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }'
else
  skip "PowerShell syntax" "pwsh not installed; CI runs it"
fi

run "bundled profile parses" python3 -c \
  "import plistlib; plistlib.load(open('macos/brave-debloat.mobileconfig','rb'))"

# Names against brave-core, the two scripts against each other, embedded Python
# syntax, ASCII-only PowerShell, bundled profile against the policy list.
run "verify-keys.py" python3 tools/verify-keys.py

# Smoke run of the macOS script with every command that touches the system
# stubbed out and HOME and TMPDIR redirected, plus a stand-in Brave profile
# seeded under that HOME.
#
# The seed matters. Without a profile directory the script prints "profile not
# found" and skips the whole preference-patching step, the largest embedded
# Python block it has, so a smoke run that never reaches it says nothing about
# it. What is checked afterwards is the outcome on the files -- values changed,
# the rest preserved, mode kept, backups and temp files as designed -- not the
# script's own output, plus the profile it generates against the one committed
# in the repository. Run twice, because the second run is what exercises backup
# rotation.
#
# Called through run() below, which shellcheck cannot see.
# shellcheck disable=SC2317,SC2329
smoke_macos() {
  local sb rc=0
  sb="$(mktemp -d)" || return 1
  smoke_macos_in "$sb" || rc=$?
  rm -rf "$sb"
  return "$rc"
}

# Called by smoke_macos, which is itself only reached through run().
# shellcheck disable=SC2317,SC2329
smoke_macos_in() {
  local sb="$1" stage c out data rc unexpected
  data="$sb/home/Library/Application Support/BraveSoftware/Brave-Browser"
  mkdir -p "$sb/bin" "$sb/tmp" "$data/Default/ads_service"

  for c in open osascript pkill defaults system_profiler; do
    printf '#!/bin/sh\nexit 0\n' >"$sb/bin/$c"
  done
  printf '#!/bin/sh\nexit 1\n' >"$sb/bin/pgrep" # Brave is "not running"
  chmod +x "$sb/bin/"*

  printf '{"keep":{"me":1},"brave":{"today":{"opted_in":true}}}' >"$data/Default/Preferences"
  printf '{"keep":true,"brave":{"p3a":{"enabled":true}}}' >"$data/Local State"
  # 640, not Brave's usual 600: 600 is also what a freshly created file gets
  # here, so only an actual copy of the original's mode can pass the check.
  chmod 640 "$data/Default/Preferences"
  chmod 600 "$data/Local State"
  cp "$data/Default/Preferences" "$sb/prefs.orig"
  cp "$data/Local State" "$sb/state.orig"

  # A second profile whose patch is made to fail after the temp file exists: a
  # dangling symlink sits where the initial backup has to be written, so the
  # copy raises. (A directory there would not do -- the script sees that the
  # path exists and skips the copy.) On the success path the rename removes the
  # temp file anyway, so this is the only way to see whether the cleanup in
  # finally actually runs. The failure must also not stop the profile processed
  # before it.
  mkdir -p "$data/Profile 1"
  ln -s "$sb/no-such-dir/target" "$data/Profile 1/Preferences.bak-initial"
  printf '{"x":1}' >"$data/Profile 1/Preferences"
  chmod 600 "$data/Profile 1/Preferences"

  for stage in first second; do
    rc=0
    out="$(PATH="$sb/bin:$PATH" HOME="$sb/home" TMPDIR="$sb/tmp/" \
      bash macos/brave-debloat.sh 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s run: script exited %s\n%s\n' "$stage" "$rc" "$out"
      return 1
    fi
    case "$out" in
      *"policies written"*) ;;
      *)
        printf '%s run: no "policies written" in output:\n%s\n' "$stage" "$out"
        return 1
        ;;
    esac
    case "$out" in
      *"profile not found"*)
        printf '%s run: the preference patcher never ran:\n%s\n' "$stage" "$out"
        return 1
        ;;
    esac
    # Exactly one profile is made to fail, on purpose; any other NOT PATCHED is
    # a real problem, and the planned one must be reported rather than hidden.
    case "$out" in
      *"NOT PATCHED Profile 1/Preferences"*) ;;
      *)
        printf '%s run: the planned failure for Profile 1 was not reported:\n%s\n' "$stage" "$out"
        return 1
        ;;
    esac
    unexpected="$(printf '%s\n' "$out" | grep 'NOT PATCHED' | grep -v 'Profile 1/Preferences' || true)"
    if [ -n "$unexpected" ]; then
      printf '%s run: unexpected failure:\n%s\n' "$stage" "$unexpected"
      return 1
    fi

    python3 - "$data" "$sb/prefs.orig" "$sb/state.orig" "$stage" <<'PY' || return 1
import glob, json, os, stat, sys

data, prefs_orig, state_orig, stage = sys.argv[1:5]
prefs_path = os.path.join(data, "Default", "Preferences")
state_path = os.path.join(data, "Local State")
problems = []


def need(condition, message):
    if not condition:
        problems.append(f"{stage} run: {message}")


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def maybe(path):
    """A missing backup should be reported, not crash the report."""
    return read(path) if os.path.exists(path) else None


def dig(doc, dotted):
    for key in dotted.split("."):
        if not isinstance(doc, dict) or key not in doc:
            return "<missing>"
        doc = doc[key]
    return doc


prefs, state = json.loads(read(prefs_path)), json.loads(read(state_path))

# What the patcher must set, including a value it has to flip from true.
need(dig(prefs, "brave.today.opted_in") is False, "Preferences: brave.today.opted_in is not false")
need(dig(prefs, "brave.rewards.enabled") is False, "Preferences: brave.rewards.enabled is not false")
need(dig(state, "brave.p3a.enabled") is False, "Local State: brave.p3a.enabled is not false")
need(dig(state, "brave.p3a.notice_acknowledged") is True, "Local State: p3a notice not acknowledged")
need(dig(state, "brave.stats.reporting_enabled") is False, "Local State: stats reporting is not false")

# And what it was not asked to touch must survive.
need(prefs.get("keep") == {"me": 1}, "Preferences: unrelated data was lost")
need(state.get("keep") is True, "Local State: unrelated data was lost")

# The original's mode, not whatever a new file would get.
for path, expected in ((prefs_path, 0o640), (state_path, 0o600)):
    mode = stat.S_IMODE(os.stat(path).st_mode)
    need(mode == expected, f"{os.path.basename(path)}: mode is {oct(mode)}, expected {oct(expected)}")

# The state from before the first run is kept for good.
need(maybe(prefs_path + ".bak-initial") == read(prefs_orig), "Preferences.bak-initial is missing or not the original")
need(maybe(state_path + ".bak-initial") == read(state_orig), "Local State.bak-initial is missing or not the original")

for path in (prefs_path, state_path):
    need(not glob.glob(path + ".tmp-*"), f"{os.path.basename(path)}: temp file left behind")
need(not os.path.exists(os.path.join(data, "Default", "ads_service")), "ads_service was not removed")

# The profile whose patch was made to fail: untouched, and no temp file left.
broken = os.path.join(data, "Profile 1", "Preferences")
need(read(broken) == '{"x":1}', "Profile 1: modified although its patch failed")
need(not glob.glob(broken + ".tmp-*"), "Profile 1: temp file left behind after a failed patch")

stamped = glob.glob(prefs_path + ".bak-2*")
if stage == "first":
    need(not stamped, "a first run should keep only .bak-initial")
else:
    need(len(stamped) == 1, f"expected one timestamped backup, found {len(stamped)}")
    if stamped:
        need(dig(json.loads(read(stamped[0])), "brave.today.opted_in") is False,
             "the timestamped backup does not hold the first run's result")

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
PY
  done

  PATH="$sb/bin:$PATH" HOME="$sb/home" bash macos/brave-debloat.sh --uninstall >/dev/null 2>&1 || {
    echo "--uninstall exited non-zero"
    return 1
  }

  python3 - "$sb/tmp/brave-debloat.mobileconfig" macos/brave-debloat.mobileconfig <<'PY'
import plistlib, sys

def policies(path):
    with open(path, "rb") as handle:
        payload = plistlib.load(handle)["PayloadContent"][0]["PayloadContent"]
    return payload["com.brave.Browser"]["Forced"][0]["mcx_preference_settings"]

generated, committed = policies(sys.argv[1]), policies(sys.argv[2])
if generated != committed:
    for key in sorted(set(generated) | set(committed)):
        if generated.get(key) != committed.get(key):
            print(f"{key}: script generates {generated.get(key)!r}, repository has {committed.get(key)!r}")
    sys.exit(1)
PY
}

if [ "$(uname)" = "Darwin" ]; then
  run "macOS smoke run (stubbed system)" smoke_macos
else
  skip "macOS smoke run" "needs macOS; CI does not run it"
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "all checks that could run passed"
else
  echo "FAILED"
fi
exit "$failed"
