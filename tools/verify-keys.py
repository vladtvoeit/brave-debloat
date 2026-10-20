#!/usr/bin/env python3
"""Check that every preference and policy name the scripts write really exists.

A wrong preference name is silent. Chromium stores only prefs that differ from
their default, so an invented key and a real one nobody has touched look
identical on disk, and the scripts report success either way. This compares the
names against brave-core instead.

GitHub code search is not usable for this: it matches substrings and ignores
case, so it confirms names that do not exist and misses names that do. Every
check here is an exact match on the quoted string.

    python3 tools/verify-keys.py
"""

import ast
import pathlib
import plistlib
import re
import sys
import urllib.error
import urllib.request

RAW = "https://raw.githubusercontent.com/brave/brave-core/master/"

# Headers that define the prefs these scripts touch.
HEADERS = [
    "components/ai_chat/core/common/pref_names.h",
    "components/brave_ads/core/public/prefs/pref_names.h",
    "components/brave_news/common/pref_names.h",
    "components/brave_rewards/core/pref_names.h",
    "components/brave_talk/pref_names.h",
    "components/brave_vpn/common/pref_names.h",
    "components/brave_wallet/browser/pref_names.h",
    "components/constants/pref_names.h",
    "components/ntp_background_images/common/pref_names.h",
    "components/ntp_background_images/common/view_counter_pref_registry.cc",
    "components/p3a/pref_names.h",
    "components/playlist/core/common/pref_names.h",
]

# Prefs and policies that are upstream Chromium, so absent from brave-core.
UPSTREAM_PREFS = {
    "browser.check_default_browser",
}
UPSTREAM_POLICIES = {
    "BackgroundModeEnabled",
    "DefaultBrowserSettingEnabled",
    "FeedbackSurveysEnabled",
    "MetricsReportingEnabled",
    "NetworkPredictionOptions",
    "PrivacySandboxAdMeasurementEnabled",
    "PrivacySandboxPromptEnabled",
    "PrivacySandboxSiteEnabledAdsEnabled",
    "PromotionalTabsEnabled",
    "SafeBrowsingExtendedReportingEnabled",
    "SpellCheckServiceEnabled",
    "UrlKeyedAnonymizedDataCollectionEnabled",
}

PREF = re.compile(r"""["']([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)["']""")
# Anchored to the end of the line, with an optional trailing comma or comment.
# Without that, a prefix match accepts typos that are valid syntax but wrong at
# run time: $falsehood reads as $false, Falsehood reads as False.
# A trailing comma belongs only in the Python dictionaries. Allowing it
# everywhere let a stray one into the bash POLICIES array, where the value
# becomes "true," — the profile generator then compares it against "true",
# finds no match and writes <false/>, inverting the policy in silence.
TAIL = r"\s*(?:\#.*)?$"
PY_TAIL = r"\s*,?" + TAIL
PY_ENTRY = re.compile(r'"([a-z][a-z0-9_.]*)"\s*:\s*(True|False)' + PY_TAIL)
PS_ENTRY = re.compile(r"'([a-z][a-z0-9_.]*)'\s*=\s*\$(true|false)" + TAIL, re.I)
PS_INDEXED = re.compile(
    r"\$profilePrefs\['([a-z][a-z0-9_.]*)'\]\s*=\s*\$(true|false)" + TAIL, re.I
)
# The value is matched literally rather than as \w+, so a typo in true/false
# fails to parse instead of quietly becoming false.
MAC_POLICY = re.compile(
    r'"([A-Za-z][A-Za-z0-9]+)\|(bool|integer)\|(true|false|\d+)"' + TAIL
)
# Indentation is not anchored: these are matched inside the extracted
# $Policies block, so there is nothing else in range to match.
WIN_POLICY = re.compile(r"([A-Za-z][A-Za-z0-9]+)\s*=\s*(\d+)" + TAIL)


def fetch(path):
    try:
        with urllib.request.urlopen(RAW + path, timeout=30) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def between(text, opener, closer):
    start = text.index(opener) + len(opener)
    return text[start:text.index(closer, start)]


def strict(block, pattern, where, failures):
    """Validate a block line by line and return what parsed.

    Matching is anchored and done per line rather than with findall over the
    whole text, so a commented-out entry is genuinely skipped instead of being
    harvested back out of the comment, and a line that does not parse is
    reported rather than passed over. Duplicate names are reported too: the
    callers build dictionaries, where one would silently win, and on macOS the
    same <key> would be written twice into the profile.
    """
    found = []
    seen = set()
    for line in block.splitlines():
        line = line.strip()
        # No brace exemption: between() already trims the block delimiters,
        # so a stray brace inside one is a mistake, not punctuation.
        if not line or line.startswith("#"):
            continue

        match = pattern.match(line)
        if not match:
            failures.append(f"{where}: cannot parse line: {line}")
            continue

        name = match.group(1)
        if name in seen:
            failures.append(f"{where}: {name} appears twice")
        seen.add(name)
        found.append(match.groups())
    return found


def grouped_prefs(mac, win, failures):
    """The three pref groups per platform, with values, so the scripts cannot
    drift in what they set or where they set it — only names were compared
    before, and a True where a False belongs would have passed."""
    to_bool = lambda s: s.lower() == "true"

    def group(text, opener, closer, pattern, where):
        raw = strict(between(text, opener, closer), pattern, where, failures)
        return {k: to_bool(v) for k, v in raw}

    mac_groups = {
        "profile": group(mac, "PROFILE = {", "\n}", PY_ENTRY, "macOS PROFILE"),
        "sponsored": group(mac, "PROFILE.update({", "})", PY_ENTRY, "macOS sponsored"),
        "local_state": group(mac, "LOCAL_STATE = {", "\n}", PY_ENTRY, "macOS LOCAL_STATE"),
    }
    win_groups = {
        "profile": group(win, "$profilePrefs = @{", "\n    }", PS_ENTRY, "Windows profilePrefs"),
        "sponsored": group(win, "if ($Sponsored) {\n", "\n    }", PS_INDEXED, "Windows sponsored"),
        "local_state": group(win, "$localState = @{", "\n    }", PS_ENTRY, "Windows localState"),
    }
    return mac_groups, win_groups


ROOT = pathlib.Path(__file__).resolve().parent.parent

PY_BLOCK = re.compile(r"<<'PY'\n(.*?)\nPY\n", re.S)
# profile_is_current and the preference patcher. A changed marker on one of
# them would otherwise drop it from the syntax check unnoticed.
EXPECTED_PY_BLOCKS = 2


def read(path):
    with open(ROOT / path, encoding="utf-8") as handle:
        return handle.read()


def main():
    mac = read("macos/brave-debloat.sh")
    win = read("windows/brave-debloat.ps1")

    failures = []

    known = set()
    for header in HEADERS:
        body = fetch(header)
        if body is None:
            print(f"FAIL  header moved or renamed: {header}")
            return 1
        known.update(PREF.findall(body))
    print(f"  {len(known)} pref names read from {len(HEADERS)} brave-core files")

    # Neither bash -n nor shellcheck looks inside a quoted heredoc, so a
    # missing comma in PROFILE would surface only at run time.
    blocks = PY_BLOCK.findall(mac)
    if len(blocks) != EXPECTED_PY_BLOCKS:
        failures.append(
            f"expected {EXPECTED_PY_BLOCKS} embedded Python blocks, found "
            f"{len(blocks)} — has a heredoc marker changed?"
        )
    for index, block in enumerate(blocks, 1):
        try:
            ast.parse(block)
        except SyntaxError as exc:
            failures.append(f"embedded Python block {index}: {exc}")
    print(f"  {len(blocks)} embedded Python blocks parsed")

    mac_groups, win_groups = grouped_prefs(mac, win, failures)

    for group in ("profile", "sponsored", "local_state"):
        left, right = mac_groups[group], win_groups[group]
        for name in sorted(set(left) | set(right)):
            if name not in right:
                failures.append(f"{group}: macOS sets {name}, Windows does not")
            elif name not in left:
                failures.append(f"{group}: Windows sets {name}, macOS does not")
            elif left[name] != right[name]:
                failures.append(
                    f"{group}: {name} is {left[name]} on macOS, {right[name]} on Windows"
                )

    # A key in the wrong dict is written to the wrong file and does nothing.
    for group in ("profile", "sponsored", "local_state"):
        for other in ("profile", "sponsored", "local_state"):
            if other <= group:
                continue
            for name in sorted(set(mac_groups[group]) & set(mac_groups[other])):
                failures.append(f"{name} appears in both {group} and {other}")

    mac_prefs = set().union(*mac_groups.values()) - UPSTREAM_PREFS
    win_prefs = set().union(*win_groups.values()) - UPSTREAM_PREFS
    for name in sorted(mac_prefs | win_prefs):
        if name not in known:
            failures.append(f"pref does not exist in brave-core: {name}")

    # Values matter as much as names: half these policies are *Disabled, where
    # off is 1, and half are *Enabled, where off is 0. A single transposed
    # digit silently turns a feature back on.
    # Parsed strictly, like the pref blocks: findall over the whole file would
    # skip a malformed entry instead of reporting it, and MAC_POLICY treats any
    # value that is not "true" as false, so a typo in the literal would pass.
    mac_policy_block = between(mac, "POLICIES=(", "\n)")
    win_policy_block = between(win, "$Policies = [ordered]@{", "\n}")
    mac_entries = strict(mac_policy_block, MAC_POLICY, "macOS POLICIES", failures)
    win_entries = strict(win_policy_block, WIN_POLICY, "Windows Policies", failures)

    # The regex accepts any of true/false/digits after either type, so the
    # pairing is checked here: "Foo|bool|1" would otherwise read as false, and
    # "Foo|integer|true" would crash int().
    # Typed once, here. The regex accepts any of true/false/digits after
    # either type, so an entry is validated before use: "Foo|bool|1" would
    # otherwise read as false, and "Foo|integer|true" would crash int() —
    # which it did, inside the profile comparison, until this was centralised.
    mac_policy_typed = {}
    mac_policy_values = {}
    mac_policy_kinds = {}
    for name, kind, value in mac_entries:
        if kind == "bool" and value in ("true", "false"):
            typed = value == "true"
        elif kind == "integer" and value.isdigit():
            typed = int(value)
        else:
            failures.append(f"policy {name} is declared {kind} but set to {value}")
            continue
        mac_policy_kinds[name] = kind
        mac_policy_typed[name] = typed
        mac_policy_values[name] = int(typed)
    win_policy_values = {name: int(value) for name, value in win_entries}

    for name in sorted(set(mac_policy_values) | set(win_policy_values)):
        if name not in win_policy_values:
            failures.append(f"policy {name} is set on macOS but not on Windows")
        elif name not in mac_policy_values:
            failures.append(f"policy {name} is set on Windows but not on macOS")
        elif mac_policy_values[name] != win_policy_values[name]:
            failures.append(
                f"policy {name} is {mac_policy_values[name]} on macOS, "
                f"{win_policy_values[name]} on Windows"
            )

    mac_policies = set(mac_policy_values)
    win_policies = set(win_policy_values)

    for name in sorted(mac_policies | win_policies):
        if name in UPSTREAM_POLICIES:
            continue
        path = f"components/policy/resources/templates/policy_definitions/BraveSoftware/{name}.yaml"
        definition = fetch(path)
        if definition is None:
            failures.append(f"policy has no definition in brave-core: {name}")
            continue

        # The YAML is already fetched, so the declared type is free to check.
        # Chromium spells a boolean policy "main" at the top level and an
        # integer one "int" or "int-enum"; "boolean" only appears indented
        # inside schema:, which is why matching it here never fired.
        declared = re.search(r"^type:\s*(\S+)", definition, re.M)
        if declared is None:
            failures.append(f"policy {name} has no type: line in brave-core")
        elif name in mac_policy_kinds:
            yaml_kind = {"main": "bool", "int": "integer", "int-enum": "integer"}.get(
                declared.group(1)
            )
            used = mac_policy_kinds[name]
            if yaml_kind is None:
                failures.append(
                    f"policy {name} has an unrecognised type in brave-core: "
                    f"{declared.group(1)}"
                )
            elif yaml_kind != used:
                failures.append(
                    f"policy {name} is {declared.group(1)} in brave-core "
                    f"({yaml_kind}) but the script writes it as {used}"
                )

    # The bundled .mobileconfig is offered as a hand-install route, so it must
    # not drift from what the script generates.
    with open(ROOT / "macos/brave-debloat.mobileconfig", "rb") as handle:
        payload = plistlib.load(handle)["PayloadContent"][0]["PayloadContent"]
    bundled = payload["com.brave.Browser"]["Forced"][0]["mcx_preference_settings"]

    expected = mac_policy_typed

    for name in sorted(set(bundled) | set(expected)):
        if name not in bundled:
            failures.append(f"bundled profile is missing policy: {name}")
        elif name not in expected:
            failures.append(f"bundled profile has a policy the script does not set: {name}")
        elif type(bundled[name]) is not type(expected[name]):
            failures.append(
                f"bundled profile has {name} as {type(bundled[name]).__name__}, "
                f"script writes {type(expected[name]).__name__}"
            )
        elif bundled[name] != expected[name]:
            failures.append(
                f"bundled profile disagrees on {name}: "
                f"{bundled[name]!r} vs {expected[name]!r}"
            )

    print(f"  {len(mac_prefs | win_prefs)} prefs and {len(mac_policies | win_policies)} policies checked")
    print(f"  bundled profile carries {len(bundled)} policies")

    if failures:
        print()
        for line in failures:
            print(f"FAIL  {line}")
        return 1

    print("  all names verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
