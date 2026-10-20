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
MAC_POLICY = re.compile(r'"([A-Za-z][A-Za-z0-9]+)\|(?:bool|integer)\|')
WIN_POLICY = re.compile(r"^\s{4}([A-Za-z][A-Za-z0-9]+)\s*=\s*\d", re.M)


def fetch(path):
    try:
        with urllib.request.urlopen(RAW + path, timeout=30) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def main():
    mac = read("macos/brave-debloat.sh")
    win = read("windows/brave-debloat.ps1")

    known = set()
    for header in HEADERS:
        body = fetch(header)
        if body is None:
            print(f"FAIL  header moved or renamed: {header}")
            return 1
        known.update(PREF.findall(body))
    print(f"  {len(known)} pref names read from {len(HEADERS)} brave-core files")

    failures = []

    mac_prefs = set(PREF.findall(mac)) - UPSTREAM_PREFS
    win_prefs = set(PREF.findall(win)) - UPSTREAM_PREFS
    for name in sorted(mac_prefs | win_prefs):
        if name not in known:
            failures.append(f"pref does not exist in brave-core: {name}")

    if mac_prefs != win_prefs:
        for name in sorted(mac_prefs ^ win_prefs):
            where = "macOS only" if name in mac_prefs else "Windows only"
            failures.append(f"the two scripts disagree ({where}): {name}")

    mac_policies = {m.group(1) for m in MAC_POLICY.finditer(mac)}
    win_policies = set(WIN_POLICY.findall(win))
    if mac_policies != win_policies:
        for name in sorted(mac_policies ^ win_policies):
            where = "macOS only" if name in mac_policies else "Windows only"
            failures.append(f"the two scripts disagree ({where}): policy {name}")

    for name in sorted(mac_policies | win_policies):
        if name in UPSTREAM_POLICIES:
            continue
        path = f"components/policy/resources/templates/policy_definitions/BraveSoftware/{name}.yaml"
        if fetch(path) is None:
            failures.append(f"policy has no definition in brave-core: {name}")

    # The bundled .mobileconfig is offered as a hand-install route, so it must
    # not drift from what the script generates.
    with open("macos/brave-debloat.mobileconfig", "rb") as handle:
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
