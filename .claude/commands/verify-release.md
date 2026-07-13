---
description: Verify a published release from the outside — appcast, update signature, notarization
allowed-tools: Bash(python3 scripts/verify-release.py*), Bash(gh release view*), Bash(gh run list*), Read
---

Verify that a **published** Tscribe release is actually safe for users to update to.

This checks what landed on the internet, not what the build said it produced. A build grading
its own homework proves less than an independent check of the artifact GitHub is really serving.

1. Run the verifier. Pass `--expect <version>` when the user named one (from `$ARGUMENTS`);
   otherwise run it bare and report whatever the feed advertises:

   ```sh
   python3 scripts/verify-release.py [--expect X.Y.Z]
   ```

   It fetches the appcast from the real feed URL, downloads the enclosure GitHub actually
   serves, and verifies:
   - the appcast is live and its enclosure length matches the download
   - the **EdDSA signature validates against the public key read out of the SHIPPED app** —
     the exact bytes that will do the checking on a user's Mac
   - the app Sparkle would install is `source=Notarized Developer ID` **and stapled**
   - all five Sparkle components (framework, Updater.app, Autoupdate, the two XPC services)
     carry the Developer ID + hardened runtime + a secure timestamp
   - the 2.9 GB model is **not** in the payload (an update is a ~41 MB app swap)

2. If anything FAILS, say so plainly and do **not** soften it. A bad release here is worse
   than a bad build: Sparkle replaces the old app *before* Gatekeeper ever sees the new one,
   so a broken update can leave someone with no working Tscribe at all. Name the failing
   check, and recommend pulling or re-cutting the release.

3. If it passes, confirm the version and build number, and report the download size.

Notes:
- Needs OpenSSL 3 for Ed25519 (`brew install openssl@3`); Apple's LibreSSL cannot do this.
- A freshly-tagged release may 404 for a minute while the Pages deploy finishes. If the feed
  isn't there yet, check `gh run list --workflow=release.yml` before concluding anything is
  wrong — and remember the `publish-appcast` job needs the `github-pages` environment to allow
  `v*` **tags** (a job that fails with zero steps and no log is that policy, not a code bug).

Don't modify anything.
