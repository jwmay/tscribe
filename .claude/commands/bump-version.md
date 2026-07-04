---
description: Bump the app version (shared by both editions) in project.yml
argument-hint: <new-version, e.g. 1.2.0>
allowed-tools: Edit, Read, Bash(xcodegen generate), Bash(git tag *), Bash(git log *)
---

Bump Tscribe's version to **$1** (both editions share one version line).

1. In `project.yml`, set `MARKETING_VERSION` to `$1` and increment `CURRENT_PROJECT_VERSION` by 1
   (it's a monotonic integer build number).
2. Run `xcodegen generate` so the generated project picks up the change.
3. Report the old → new values.
4. Do **not** commit or tag unless the user asks. If they want to release, remind them that pushing
   a `vX.Y.Z` tag triggers the Standard CI release (`.github/workflows/release.yml`), and the tag should
   match `$1`.

If `$1` is empty, ask for the target version instead of guessing.
