#### Signing & Notarization (required for macOS 26+)

Starting v{{NEXT_VERSION}}, release binaries are signed with a Developer ID Application certificate and notarized via Apple's `notarytool`. This is **required** on macOS 26 — ad-hoc signed binaries cannot trigger Calendar / Reminders / AppleEvents TCC permission dialogs there.

**Prerequisites** (one-time setup):

1. Apple Developer Program enrollment.
2. Developer ID Application certificate installed in login keychain.
   - Verify with: `security find-identity -p codesigning -v` (must show `Developer ID Application: <Your Name> (<TeamID>)`).
   - Your Team ID is your own — find it at <https://developer.apple.com/account> → Membership Details.
3. `notarytool` keychain profile (any name; suggest `{{NOTARY_PROFILE_DEFAULT}}`).
   - Create interactively (recommended — keeps password out of shell history):
     ```bash
     xcrun notarytool store-credentials {{NOTARY_PROFILE_DEFAULT}} --apple-id <your-apple-id> --team-id <your-team-id>
     # notarytool will prompt for the app-specific password
     ```
   - App-specific password: generate at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords. Use a single-purpose password (named e.g. `{{NOTARY_PROFILE_DEFAULT}}`); revoke + regenerate if leaked. **Never** pass it via `--password` on the command line — it lands in `~/.zsh_history`.
4. Export your identity for the build script:
   ```bash
   export DEVELOPER_ID='Developer ID Application: <Your Name> (<TeamID>)'
   export NOTARY_PROFILE='{{NOTARY_PROFILE_DEFAULT}}'   # match what you set up in step 3
   ```
   Persist these in `~/.zshrc` or a project-local `.envrc` (gitignored). The script intentionally has **no defaults** for these, so a fresh fork doesn't fail with errors referring to the maintainer's identity.

**Per-release flow**:

```bash
make release-signed     # builds → signs + notarizes → packages
gh release create vX.Y.Z <path-to-binary> [<path-to-mcpb>] --notes "..."
```

`make release-signed` runs `scripts/build-mcpb.sh` (or `build-cli.sh`) with `REQUIRE_CODESIGN=1` so missing prerequisites fail-fast. After universal binary creation, `scripts/sign-and-notarize.sh` performs codesign + notarization. Notarization typically takes 1–15 minutes (`notarytool submit --wait` blocks until Apple finishes).

**Verification** after build (run all three to confirm end-to-end):

```bash
# 1. Signature properties (cert + hardened runtime + team ID)
codesign -dv --verbose=2 path/to/{{TARGET_NAME}}
# Expected:
#   Authority=Developer ID Application: <Your Name> (<TeamID>)
#   TeamIdentifier=<TeamID>
#   flags=0x10000(runtime)

# 2. Signature integrity
codesign --verify --deep --strict --verbose=2 path/to/{{TARGET_NAME}}
# Expected: exit 0, no warnings

# 3. Notarization end-to-end (this is the real "Gatekeeper would accept" gate)
spctl -a -vvv -t install path/to/{{TARGET_NAME}}
# Expected: <binary>: accepted; source=Notarized Developer ID
#
# Note on flag choice (verified empirically on macOS 26.4.1):
#   -t execute → rejected "code is valid but does not seem to be an app"
#                (Apple's "execute" type expects a .app bundle structure,
#                 not raw Mach-O CLI binaries)
#   -t install → accepted; source=Notarized Developer ID  ← use this
#
# Apple's Code Signing Guide describes -t execute as the assessment type for
# "applications and tools", but on macOS 26 raw Mach-O binaries fall through
# the .app bundle check. -t install is the documented assessment type for
# software being installed (which describes how a CLI binary lands in ~/bin),
# and is the type that returns the actual notarization verdict in practice.
# Re-test if Apple changes this behavior in a future macOS update.
```

**Local dev iteration** without signing latency:

```bash
SKIP_CODESIGN=1 ./scripts/build-mcpb.sh   # ad-hoc signed; do NOT ship the result
make install                              # installs ad-hoc to ~/bin (dev only)
```

The build script also **auto-skips signing** when `DEVELOPER_ID` is unset OR the cert isn't in your keychain — so contributors / CI / forks can build a working unsigned artifact for testing without manually setting `SKIP_CODESIGN`. (You'll see a clear "Skipping codesign" warning when this happens.) `make release-signed` enforces signing via `REQUIRE_CODESIGN=1` and fails fast if anything is missing.

**Signing identity environment**:

| Env var | Default | Required for |
|---------|---------|--------------|
| `DEVELOPER_ID` | _(unset — auto-skip signing)_ | Signed release |
| `NOTARY_PROFILE` | _(unset — fail-fast in `sign-and-notarize.sh`)_ | Signed release |
| `ENTITLEMENTS` | `Sources/{{TARGET_NAME}}/Entitlements.plist` | Custom entitlements file |
| `SKIP_CODESIGN` | _(unset)_ | Force-skip signing even with cert present (set to `1` or `true`) |
| `REQUIRE_CODESIGN` | _(unset)_ | Fail-fast if signing prerequisites missing (set to `1` by `make release-signed`) |

**Known limitation — no stapling**: `stapler staple` does not support raw Mach-O binaries (only `.app` / `.pkg` / `.dmg` bundles). After notarization, Gatekeeper will online-check the binary on first launch instead of reading a stapled ticket. End users behind air-gapped networks may see "cannot verify developer" warnings; one launch with network resolves it (Apple caches the verdict). Mitigation: `xcrun stapler staple` on a future `.pkg` wrapper if needed.

**Upgrade trap (if shipping over an existing install)**: If users have an older version of `{{TARGET_NAME}}` already installed (e.g. ad-hoc signed prior version), they should `rm -f` the old binary before replacing it. macOS caches code-signature hashes per-inode; copying a new binary over an inode held open by a still-running old process leaves a stale cache that causes the kernel to kill the new binary on exec with "load code signature error 2". The `Makefile install:` target and the user-facing install instructions both use `rm -f` defensively.

**Troubleshooting**:

- Notarization rejected? `xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE` shows Apple's reason. The signing script prints the submission ID on every run.
- `codesign` complains about missing identity? `security find-identity -p codesigning -v` to confirm cert is present + valid; `xcrun notarytool history --keychain-profile $NOTARY_PROFILE` to confirm the profile works.
- Cert expired? Re-issue at <https://developer.apple.com/account/resources/certificates>, install, re-export `DEVELOPER_ID`.
- Security warning: don't unlock signing keychain on shared / untrusted machines. The cert + private key signing artifact is supply-chain critical.
