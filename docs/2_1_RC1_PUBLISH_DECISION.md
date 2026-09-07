# ESH 2.1 RC1 — READY TO PUBLISH

Everything preparable without an externally-visible action is done and on `main`. One action remains, and it
is yours.

## Stopping-state checklist
```
Heavy capability e2e qualification       ✅  (image gen/edit/upscale, SFX via /v1/execute; video pipeline sound)
Qualification matrix final               ✅  docs/2_1_RELEASE_QUALIFICATION_MATRIX.md
Feature freeze intact                    ✅  docs/2_1_FEATURE_FREEZE.md
Full regression                          ✅  167 tests / 24 suites, 0 failures
CI                                       ✅  green on main
Public docs                              ✅  docs/2_1_PUBLIC_GUIDE.md
Release notes                            ✅  docs/2_1_RELEASE_NOTES_RC1.md
Fresh RC artifact                        ✅  pipeline verified; CI builds the publishable one clean on tag
Package smoke                            ✅  smoke: ok
Fresh-install smoke                      ✅  version 2.1.0-rc.1, doctor, CLI/Web/voice/APIs/GGUF; no dev-path leak
Upgrade-path smoke                       ◑  updater verified (brew upgrade --cask esh); actual 2.0→2.1 needs publish
Homebrew RC prep                         ✅  generator + CI tap update wired
Signing prep                             ✅  local Developer ID sign verified (hardened runtime + timestamp)
Notarization prep                        ✅  script + CI secrets wired (runs on tag)

Only external publish/credential action  → USER
```
Two items are environment-limited, not effort- or credential-limited: a clean-venv *local* MLX re-verify
(dev-machine disk ~100% full — the publishable venv is CI-built clean, and the MLX capabilities are verified
working in Phase A), and the actual 2.0→2.1 upgrade (needs the release to exist first). Both are covered by the
publish itself.

## 1. Exact remaining action you must perform
Push the release tag (or dispatch the workflow). This is the only externally-visible, irreversible step:
```bash
git tag v2.1.0-rc.1 && git push origin v2.1.0-rc.1
```
(Alternative, no tag: `gh workflow run release.yml -f publish_release=true`.)
This triggers `.github/workflows/release.yml`, which builds a FRESH artifact with clean python, signs,
notarizes, publishes the GitHub pre-release, and updates the Homebrew tap — all headless in CI.

## 2. Credentials — already configured?
- **Signing:** ✅ `Developer ID Application: Sviatoslav Fil (L7T5538V86)` present locally (verified a real
  signature) **and** referenced as CI secrets (`APPLE_DEVELOPER_ID`, `APPLE_CERT_P12_BASE64`,
  `APPLE_CERT_PASSWORD`).
- **Notarization:** ⚠️ needs `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_PRIVATE_KEY_P8`,
  `APPLE_TEAM_ID` — referenced as CI secrets (the same set the 2.0 release line used); **not present in the
  local env**. I cannot read GitHub secret values to 100%-confirm they are set/valid — **please confirm these
  four secrets exist in the repo/org settings**, or the notarize step will fail.
- **Homebrew:** `HOMEBREW_TAP_TOKEN` referenced as a CI secret for `fil-technology/homebrew-tap`.

## 3. Exact proposed tag / version
- VERSION (on `main`): `2.1.0-rc.1`  ·  Tag: `v2.1.0-rc.1`  ·  Published as a **pre-release**.

## 4. Exact artifact(s)
Built fresh by CI: `esh-macos-2.1.0-rc.1.tar.gz` and `esh-macos-2.1.0-rc.1.zip` (signed + notarized), plus the
Homebrew cask update in `fil-technology/homebrew-tap`.

## 5. Exact release notes
`docs/2_1_RELEASE_NOTES_RC1.md` (attach/paste as the GitHub release body).

## 6. Exact publish commands/actions
```bash
# from a clean checkout of main at the intended commit (VERSION must read 2.1.0-rc.1):
git tag v2.1.0-rc.1
git push origin v2.1.0-rc.1
# watch it:
gh run watch $(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

## 7. What becomes publicly visible
- A **GitHub pre-release `v2.1.0-rc.1`** on `fil-technology/esh` with the signed+notarized artifacts and the
  release notes.
- A commit in the public **`fil-technology/homebrew-tap`** updating the esh cask to the RC.
- (No effect on the stable channel unless someone opts into the RC.)

## 8. Rollback procedure
```bash
gh release delete v2.1.0-rc.1 --yes           # remove the GitHub (pre-)release
git push origin :refs/tags/v2.1.0-rc.1        # delete the remote tag
```
Then revert the Homebrew tap commit (`git -C homebrew-tap revert <sha> && git push`) so `brew` no longer offers
the RC. Because it is a pre-release, only users who explicitly installed the RC are affected; the stable channel
is untouched.
