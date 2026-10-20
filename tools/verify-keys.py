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
PY_ENTRY = re.compile(r'"([a-z][a-z0-9_.]*)"\s*:\s*(True|False)')
PS_ENTRY = re.compile(r"'([a-z][a-z0-9_.]*)'\s*=\s*\$(true|false)", re.I)
PS_INDEXED = re.compile(r"\$profilePrefs\['([a-z][a-z0-9_.]*)'\]\s*=\s*\$(true|false)", re.I)
# The value is matched literally rather than as \w+, so a typo in true/false
# fails to parse instead of quietly becoming false.
MAC_POLICY = re.compile(r'"([A-Za-z][A-Za-z0-9]+)\|(bool|integer)\|(true|false|\d+)"')
# Indentation is not anchored: these are matched inside the extracted
# $Policies block, so there is nothing else in range to match.
WIN_POLICY = re.compile(r"^\s*([A-Za-z][A-Za-z0-9]+)\s*=\s*(\d+)", re.M)


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
    """Every meaningful line in a pref block must parse. A findall that simply
    skips an unrecognised line would let a typo through silently — the exact
    failure mode this whole script exists to prevent."""
    for line in block.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line in ("}", "})", "{"):
            continue
        if not pattern.search(line):
            failures.append(f"{where}: cannot parse line: {line}")
    return pattern.findall(block)


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
    strict(mac_policy_block, MAC_POLICY, "macOS POLICIES", failures)
    strict(win_policy_block, WIN_POLICY, "Windows Policies", failures)

    mac_policy_values = {
        name: (1 if value == "true" else 0) if kind == "bool" else int(value)
        for name, kind, value in MAC_POLICY.findall(mac_policy_block)
    }
    mac_policy_kinds = {name: kind for name, kind, _ in MAC_POLICY.findall(mac_policy_block)}
    win_policy_values = {name: int(value) for name, value in WIN_POLICY.findall(win_policy_block)}

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
        if declared and name in mac_policy_kinds:
            yaml_kind = {"main": "bool", "int": "integer", "int-enum": "integer"}.get(
                declared.group(1)
            )
            used = mac_policy_kinds[name]
            if yaml_kind and yaml_kind != used:
                failures.append(
                    f"policy {name} is {declared.group(1)} in brave-core "
                    f"({yaml_kind}) but the script writes it as {used}"
                )

    # The bundled .mobileconfig is offered as a hand-install route, so it must
    # not drift from what the script generates.
    with open(ROOT / "macos/brave-debloat.mobileconfig", "rb") as handle:
        payload = plistlib.load(handle)["PayloadContent"][0]["PayloadContent"]
    bundled = payload["com.brave.Browser"]["Forced"][0]["mcx_preference_settings"]

    expected = {}
    for name, kind, value in re.findall(
        r'"([A-Za-z][A-Za-z0-9]+)\|(bool|integer)\|(\w+)"', mac
    ):
        expected[name] = value == "true" if kind == "bool" else int(value)

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
