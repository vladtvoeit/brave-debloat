#!/usr/bin/env bash
# Run every check this project has that can run on this machine.
#
#   tools/check.sh
#
# Exit status is non-zero if anything failed. A check whose tool is missing is
# reported as SKIP and says so out loud: a check that quietly does not run reads
# exactly like one that passed, which is the failure this project keeps
# running into. CI covers what is skipped here (shellcheck, PowerShell parsing).
#
# Needs network: verify-keys.py reads brave-core.

set -u
cd "$(dirname "$0")/.." || exit 2

# Keep review runs from leaving __pycache__ behind in the working tree.
export PYTHONDONTWRITEBYTECODE=1

failed=0

pass() { printf '  ok    %s\n' "$1"; }
skip() { printf '  SKIP  %s  (%s not installed; CI runs it)\n' "$1" "$2"; }
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

echo "brave-debloat checks"

run "bash syntax" bash -n macos/brave-debloat.sh

if command -v shellcheck >/dev/null 2>&1; then
  run "shellcheck" shellcheck macos/brave-debloat.sh
else
  skip "shellcheck" shellcheck
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
  skip "PowerShell syntax" pwsh
fi

run "bundled profile parses" python3 -c \
  "import plistlib; plistlib.load(open('macos/brave-debloat.mobileconfig','rb'))"

# Names against brave-core, the two scripts against each other, embedded Python
# syntax, ASCII-only PowerShell, bundled profile against the policy list.
run "verify-keys.py" python3 tools/verify-keys.py

# Smoke run of the macOS script with every command that touches the system
# stubbed out, HOME and TMPDIR redirected. Exercises everything except the
# manual profile install, and compares the profile it generates with the one
# committed in the repository.
# Called through run() below, which shellcheck cannot see.
# shellcheck disable=SC2329
smoke_macos() {
  local sb c out rc=0
  sb="$(mktemp -d)" || return 1
  mkdir -p "$sb/bin" "$sb/home" "$sb/tmp"

  for c in open osascript pkill defaults system_profiler; do
    printf '#!/bin/sh\nexit 0\n' >"$sb/bin/$c"
  done
  printf '#!/bin/sh\nexit 1\n' >"$sb/bin/pgrep" # Brave is "not running"
  chmod +x "$sb/bin/"*

  out="$(PATH="$sb/bin:$PATH" HOME="$sb/home" TMPDIR="$sb/tmp/" \
    bash macos/brave-debloat.sh 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'script exited %s\n%s\n' "$rc" "$out"
    rm -rf "$sb"
    return 1
  fi
  case "$out" in
    *"policies written"*) ;;
    *)
      printf 'no "policies written" in output:\n%s\n' "$out"
      rm -rf "$sb"
      return 1
      ;;
  esac

  PATH="$sb/bin:$PATH" HOME="$sb/home" bash macos/brave-debloat.sh --uninstall >/dev/null 2>&1 || {
    echo "--uninstall exited non-zero"
    rm -rf "$sb"
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
  rc=$?
  rm -rf "$sb"
  return "$rc"
}

if [ "$(uname)" = "Darwin" ]; then
  run "macOS smoke run (stubbed system)" smoke_macos
else
  skip "macOS smoke run" "macOS"
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "all checks that could run passed"
else
  echo "FAILED"
fi
exit "$failed"
