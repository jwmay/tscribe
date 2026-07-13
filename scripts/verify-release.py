#!/usr/bin/env python3
"""Verify a PUBLISHED Tscribe release the way a user's Mac would.

The build already checks itself (package.sh signs and audits; CI refuses to publish an
un-notarized artifact). This script exists because a build grading its own homework proves
less than an independent check of what actually landed on the internet. So it trusts nothing
local: it fetches the appcast from the real feed URL, downloads the enclosure GitHub actually
serves, and verifies the EdDSA signature against the public key read out of the SHIPPED app —
the exact byte string that will be doing the checking on a lawyer's laptop.

What it proves:
  * the appcast is live, and advertises the version it should
  * the enclosure downloads, and matches the length the appcast claims
  * the update is signed by our key AS THE SHIPPED APP UNDERSTANDS IT
  * the app Sparkle would install is notarized + stapled (validates with no network)
  * all of Sparkle's nested code carries our Developer ID, not its ad-hoc signature
  * the 2.9 GB model is NOT in the payload (an update is an app swap, not a re-download)

Usage:  python3 scripts/verify-release.py [--expect 2.1.0]
Exit 0 = everything a user needs is true. Exit 1 = do not let people update to this.
"""
import argparse
import base64
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPARKLE_PLIST = os.path.join(REPO, "assets", "Info-Sparkle.plist")

# Ed25519 SubjectPublicKeyInfo prefix — lets openssl accept Sparkle's raw 32-byte key.
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")

failures = []


def check(label, passed, detail=""):
    print(f"  {'PASS' if passed else 'FAIL'}  {label}" + (f"  — {detail}" if detail else ""))
    if not passed:
        failures.append(label)


def openssl():
    for p in ("/opt/homebrew/opt/openssl@3/bin", "/usr/local/opt/openssl@3/bin"):
        exe = shutil.which("openssl", path=p)
        if exe:
            return exe
    # LibreSSL (Apple's /usr/bin/openssl) lacks -rawin and cannot do this check.
    exe = shutil.which("openssl")
    ver = subprocess.run([exe, "version"], capture_output=True, text=True).stdout
    if "LibreSSL" in ver:
        sys.exit("Need OpenSSL 3 for Ed25519 (-rawin); Apple's LibreSSL can't. `brew install openssl@3`")
    return exe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--expect", help="version that should be advertised, e.g. 2.1.0")
    args = ap.parse_args()

    # The feed URL comes from the same file the app is built from, so this script can't be
    # checking a different endpoint than the one that ships.
    feed = plistlib.load(open(SPARKLE_PLIST, "rb"))["SUFeedURL"]
    print(f"Feed: {feed}\n")

    xml = urllib.request.urlopen(feed, timeout=30).read().decode()
    sig_b64 = re.search(r'sparkle:edSignature="([^"]+)"', xml).group(1)
    url = re.search(r'<enclosure url="([^"]+)"', xml).group(1)
    length = int(re.search(r'length="(\d+)"', xml).group(1))
    version = re.search(r"<sparkle:shortVersionString>([^<]+)", xml).group(1)
    build = re.search(r"<sparkle:version>([^<]+)", xml).group(1)
    print(f"  advertises {version} (build {build})\n  enclosure  {url}\n")

    if args.expect:
        check(f"appcast advertises {args.expect}", version == args.expect, version)

    tmp = tempfile.mkdtemp()
    try:
        zpath = os.path.join(tmp, "Tscribe.zip")
        urllib.request.urlretrieve(url, zpath)
        blob = open(zpath, "rb").read()
        check("enclosure length matches the appcast", len(blob) == length, f"{len(blob)} bytes")

        subprocess.run(["ditto", "-x", "-k", zpath, tmp], check=True, capture_output=True)
        app = os.path.join(tmp, "Tscribe.app")
        info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))

        check("shipped app points at this very feed", info["SUFeedURL"] == feed)
        check("shipped app's version matches the appcast",
              info["CFBundleShortVersionString"] == version and info["CFBundleVersion"] == build,
              f"{info['CFBundleShortVersionString']} / build {info['CFBundleVersion']}")

        # The one that matters: does the key INSIDE the app accept this update?
        pub = base64.b64decode(info["SUPublicEDKey"])
        open(f"{tmp}/pub.der", "wb").write(SPKI_PREFIX + pub)
        open(f"{tmp}/sig.bin", "wb").write(base64.b64decode(sig_b64))
        ossl = openssl()
        subprocess.run([ossl, "pkey", "-pubin", "-inform", "DER", "-in", f"{tmp}/pub.der",
                        "-out", f"{tmp}/pub.pem"], check=True, capture_output=True)
        r = subprocess.run([ossl, "pkeyutl", "-verify", "-pubin", "-inkey", f"{tmp}/pub.pem",
                            "-rawin", "-in", zpath, "-sigfile", f"{tmp}/sig.bin"],
                           capture_output=True, text=True)
        check("EdDSA signature verifies against the shipped app's own public key",
              "Success" in r.stdout, (r.stdout or r.stderr).strip())

        out = subprocess.run(["spctl", "-a", "-vvv", "-t", "exec", app],
                             capture_output=True, text=True)
        combined = out.stdout + out.stderr
        # Sparkle itself would install an un-notarized build quite happily, so this is not
        # redundant with the signature check — it's the Gatekeeper story on next launch.
        check("app Sparkle installs is source=Notarized Developer ID",
              "source=Notarized Developer ID" in combined,
              next((l.strip() for l in combined.splitlines() if "source=" in l), ""))
        check("notarization ticket is stapled (no network needed to launch)",
              subprocess.run(["xcrun", "stapler", "validate", app],
                             capture_output=True).returncode == 0)
        check("codesign --verify --deep --strict",
              subprocess.run(["codesign", "--verify", "--deep", "--strict", app],
                             capture_output=True).returncode == 0)

        fw = "Contents/Frameworks/Sparkle.framework"
        for comp in [fw, f"{fw}/Versions/B/Updater.app", f"{fw}/Versions/B/Autoupdate",
                     f"{fw}/Versions/B/XPCServices/Downloader.xpc",
                     f"{fw}/Versions/B/XPCServices/Installer.xpc"]:
            r = subprocess.run(["codesign", "-dv", "--verbose=4", os.path.join(app, comp)],
                               capture_output=True, text=True)
            t = r.stdout + r.stderr
            flags = re.search(r"flags=\S+", t)
            good = ("Authority=Developer ID Application" in t
                    and flags and "runtime" in flags.group(0)
                    and "Timestamp=" in t)
            check(f"Sparkle/{os.path.basename(comp)}: Developer ID + runtime + timestamp", good)

        models = subprocess.run(["find", app, "-name", "*large-v3*"],
                                capture_output=True, text=True).stdout.split()
        check("no 2.9 GB model inside the update payload", not models)
        mb = int(subprocess.run(["du", "-sm", app], capture_output=True, text=True).stdout.split()[0])
        check("update is a small app swap", mb < 200, f"{mb} MB app, {len(blob) // 1048576} MB download")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if failures:
        print(f"FAILED ({len(failures)}): " + "; ".join(failures))
        print("Do NOT leave this release published — users may be unable to update, or may end up")
        print("with an app that Gatekeeper blocks after the old one is already gone.")
        return 1
    print(f"All checks passed. {version} (build {build}) is safe to update to.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
