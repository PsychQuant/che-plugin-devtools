---
name: mcp-sign-pipeline
description: Apply Developer ID signing + notarization pipeline to a Swift MCP / CLI project. Required for macOS 26 — ad-hoc signed binaries can no longer trigger TCC permission dialogs. Use when creating new MCP/CLI (mcp-new-app / cli-new-app integration) OR upgrading an existing project that needs to ship signed releases. Templates are extracted from che-ical-mcp PR #44 (production-verified on macOS 26.4.1) and parameterized for any Swift binary project.
---

# mcp-sign-pipeline — Apply signing + notarization pipeline

## When this skill triggers

User says any of:
- "簽章 / sign / notarize / Developer ID / macOS 26 TCC"
- "我的 MCP/CLI 在 macOS 26 上不工作了"
- "TCC dialog 不出現"
- "Gatekeeper 拒絕我的 binary"
- Building a new Swift MCP/CLI that touches TCC-protected APIs (EventKit, AppleEvents, Photos, Mic, Camera, Full Disk Access)

This skill installs the full signing + notarization pipeline into the target project. It's the productionized version of `che-ical-mcp` PR #44.

## Scope

**Installs**:
- `Sources/<TargetName>/Entitlements.plist` (empty `<dict/>` — minimal entitlements)
- `scripts/sign-and-notarize.sh` (with pre-flight cert + notarytool checks, mktemp + trap, fail-soft submission ID extraction)
- Modifies `scripts/build-mcpb.sh` (or equivalent build script) — adds `[3.5/N]` sign step gated by `SKIP_CODESIGN` / `REQUIRE_CODESIGN`
- Modifies `Makefile` — new `release-signed` target with fail-fast on missing env vars; `install:` target gets `rm -f` prefix (#62 inode-cache trap fix)
- Updates `README.md` — adds "Signing & Notarization" subsection under "Release Process"
- Updates `CHANGELOG.md` — adds "Distribution" entry under current version

**Does NOT do**:
- Apply for Developer ID Application cert (manual, via developer.apple.com)
- Set up notarytool keychain profile (manual, requires app-specific password)
- Verify on macOS 26 hardware (manual end-to-end test)
- GitHub Actions CI integration (out of MVP scope; defer to follow-up issue)

## Prerequisites (the user must have these — skill does not create them)

1. **Apple Developer Program enrollment** ($99/yr)
2. **Developer ID Application certificate** in login keychain
   - Verify: `security find-identity -p codesigning -v` shows `Developer ID Application: ...`
3. **`notarytool` keychain profile** (any name; this skill uses `$NOTARY_PROFILE` env var)
   - Create with: `xcrun notarytool store-credentials <profile-name> --apple-id <id> --team-id <team-id>` (interactive — NOT `--password`)
4. **App-specific password** generated at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords

The skill emits friendly error messages from the install scripts pointing users to these prereqs if any are missing.

## Execution

### Step 0: Bootstrap Stage Task List (mandatory)

```
TaskCreate(name="resolve_target_project", description="Determine target project: --target flag OR current dir's Package.swift OR ask")
TaskCreate(name="probe_project_shape", description="Detect: Swift Package? Target name? Existing scripts/? Existing Makefile? README format? CHANGELOG format?")
TaskCreate(name="check_prereqs_env", description="Optional: probe DEVELOPER_ID + cert + notarytool profile and warn early if missing")
TaskCreate(name="apply_entitlements_plist", description="Write Sources/<Target>/Entitlements.plist (empty <dict/>)")
TaskCreate(name="apply_sign_script", description="Write scripts/sign-and-notarize.sh (chmod +x)")
TaskCreate(name="apply_build_script_changes", description="Modify scripts/build-mcpb.sh (or build-cli.sh) — add [3.5/N] step, REQUIRE_CODESIGN gating")
TaskCreate(name="apply_makefile_changes", description="Modify Makefile — add release-signed target with fail-fast; rm -f in install: target")
TaskCreate(name="apply_readme_section", description="Inject Signing & Notarization subsection into README.md Release Process")
TaskCreate(name="apply_changelog_entry", description="Inject Distribution subsection into CHANGELOG.md current version")
TaskCreate(name="present_diff_summary", description="Show diff stats; AskUserQuestion to confirm before commit")
TaskCreate(name="commit_and_recommend_next", description="git commit (conventional fix:) + recommend manual macOS 26 verification + tag")
```

### Step 1: Resolve target project

Args:
- `--target /path/to/repo` (preferred — explicit)
- `--target-name <Name>` (Sources/<Name>/Entitlements.plist needs this)
- No flag → use $PWD; ask `--target-name` via AskUserQuestion

Probe:

```bash
TARGET="${TARGET:-$PWD}"
[[ ! -f "$TARGET/Package.swift" ]] && abort "Not a Swift Package: no Package.swift found"

# Auto-detect target name from Package.swift if not given
if [[ -z "$TARGET_NAME" ]]; then
    TARGET_NAME=$(grep -oE '\.executable\(name:\s*"[^"]+"' "$TARGET/Package.swift" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    [[ -z "$TARGET_NAME" ]] && AskUserQuestion "What's the target name? (will be used in Sources/<Name>/Entitlements.plist)"
fi
```

### Step 2: Probe project shape

Detect existing artifacts to know what to edit vs create:

```bash
HAS_BUILD_SCRIPT=$([ -f "$TARGET/scripts/build-mcpb.sh" ] || [ -f "$TARGET/scripts/build-cli.sh" ] && echo "yes" || echo "no")
BUILD_SCRIPT_PATH=$([ -f "$TARGET/scripts/build-mcpb.sh" ] && echo "scripts/build-mcpb.sh" || echo "scripts/build-cli.sh")
HAS_MAKEFILE=$([ -f "$TARGET/Makefile" ] && echo "yes" || echo "no")
HAS_README=$([ -f "$TARGET/README.md" ] && echo "yes" || echo "no")
HAS_CHANGELOG=$([ -f "$TARGET/CHANGELOG.md" ] && echo "yes" || echo "no")
HAS_ENTITLEMENTS=$([ -f "$TARGET/Sources/$TARGET_NAME/Entitlements.plist" ] && echo "yes" || echo "no")
HAS_SIGN_SCRIPT=$([ -f "$TARGET/scripts/sign-and-notarize.sh" ] && echo "yes" || echo "no")
```

Report what exists vs what will be added.

### Step 3: Apply files (one bash call per concern)

Use the templates in `templates/` directory (see Templates section below).

#### Step 3.1: Entitlements.plist

```bash
mkdir -p "$TARGET/Sources/$TARGET_NAME"
cp "$SKILL_DIR/templates/Entitlements.plist" "$TARGET/Sources/$TARGET_NAME/Entitlements.plist"
```

#### Step 3.2: sign-and-notarize.sh

Template needs no parameterization — it's already env-var driven (DEVELOPER_ID, NOTARY_PROFILE, ENTITLEMENTS).

```bash
mkdir -p "$TARGET/scripts"
cp "$SKILL_DIR/templates/sign-and-notarize.sh" "$TARGET/scripts/sign-and-notarize.sh"
chmod +x "$TARGET/scripts/sign-and-notarize.sh"
```

#### Step 3.3: Modify build script (build-mcpb.sh / build-cli.sh)

Insert `[3.5/N]` sign step after the universal binary creation, before `mcpb pack` (or equivalent final step).

Three insertion points to find:
1. Variable `UNIVERSAL_BINARY` (or equivalent — the path to the built binary)
2. After `lipo -create ... -output "$UNIVERSAL_BINARY"`
3. Before any packaging step

Template snippet at `templates/build-script-step-3.5.sh`. Inject between the lipo step and the next major step.

For `build-mcpb.sh` ad-hoc trap fix: also add `rm -f "$UNIVERSAL_BINARY"` BEFORE `lipo -create` (#62 fix).

If user already has Step 3.5 installed (e.g. they're upgrading mid-cycle), detect via `grep "REQUIRE_CODESIGN" "$BUILD_SCRIPT_PATH"` and abort with "already installed".

#### Step 3.4: Makefile changes

Two changes:

1. **Add `release-signed` target**:
```makefile
.PHONY: build release release-signed install clean test
# ... existing ...
release-signed:
	@echo "⚠ macOS 26 TCC behavior on the resulting binary remains unverified."
	@echo "  Manual test required before tagging — install on macOS 26 and run --setup."
	@echo ""
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See README 'Signing & Notarization' for setup.}
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set. See README 'Signing & Notarization' for setup.}
	REQUIRE_CODESIGN=1 ./scripts/build-mcpb.sh
```

2. **Modify `install:` target** to add `rm -f` prefix (#62 fix):
```makefile
install: release
	rm -f ~/bin/$(BINARY_NAME)
	cp .build/release/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	codesign --force --sign - ~/bin/$(BINARY_NAME)
	@echo "Installed: ~/bin/$(BINARY_NAME) (ad-hoc signed — dev only)"
```

If `install:` target doesn't exist, create it. If exists, only add `rm -f` line at the start of recipe.

#### Step 3.5: README "Signing & Notarization" subsection

Append to README.md, ideally under "Release Process (for maintainers)" section. If no Release Process section, append at end.

Template at `templates/README-signing-section.md`. Substitutions:
- `{{TARGET_NAME}}` → e.g. `CheICalMCP`
- `{{NOTARY_PROFILE_DEFAULT}}` → e.g. `che-ical-mcp` (suggested name based on target lowercase)

#### Step 3.6: CHANGELOG entry

Find current version's section in CHANGELOG.md (e.g. `## [1.7.1]`). Inject `### Distribution` subsection at the top of the section's body.

Template at `templates/changelog-distribution.md`.

If user is currently on `[Unreleased]` only, ask whether to inject there or pin to a specific version.

### Step 4: Present diff summary

```
=== mcp-sign-pipeline applied to {target} ===
NEW:
  Sources/{TargetName}/Entitlements.plist            (5 lines)
  scripts/sign-and-notarize.sh                       (~150 lines)
MODIFIED:
  scripts/build-mcpb.sh                              (+~30 lines: REQUIRE_CODESIGN gate)
  Makefile                                           (+~12 lines: release-signed target)
  README.md                                          (+~70 lines: Signing & Notarization)
  CHANGELOG.md                                       (+~10 lines: Distribution entry)

NEXT STEPS for user:
  1. Verify cert: security find-identity -p codesigning -v
  2. Set up notarytool profile: xcrun notarytool store-credentials <name>
  3. export DEVELOPER_ID='Developer ID Application: <Your Name> (<TeamID>)'
  4. export NOTARY_PROFILE='<your-profile-name>'
  5. make release-signed (will fail-fast if any prereq missing)
  6. Test on macOS 26 hardware: install + ~/bin/<TargetName> --setup
```

### Step 5: Commit & recommend next

```bash
git add Sources/$TARGET_NAME/Entitlements.plist scripts/sign-and-notarize.sh scripts/build-mcpb.sh Makefile README.md CHANGELOG.md
git commit -m "feat: add Developer ID signing + notarization pipeline (macOS 26 TCC)

Applied via mcp-sign-pipeline skill. Required on macOS 26 — ad-hoc
signed binaries can no longer trigger Calendar/Reminders/AppleEvents
TCC permission dialogs.

Components:
- Sources/<Target>/Entitlements.plist (empty <dict/>; hardened runtime
  is the macOS 26 TCC trigger; no entitlement keys needed)
- scripts/sign-and-notarize.sh (codesign + verify + notarize +
  pre-flight checks + friendly error messages)
- scripts/build-mcpb.sh: new [3.5/N] sign step; REQUIRE_CODESIGN=1
  gates canonical release path; auto-skip with warning otherwise
- Makefile: new release-signed target; install: gets rm -f to prevent
  inode-cache SIGKILL trap on upgrades
- README/CHANGELOG: Signing & Notarization docs + entry

Manual macOS 26 verification gates first signed release."
```

### Step 6: Auto-update integration (optional)

If invoked from `mcp-new-app` or `cli-new-app`, return control to the parent skill. If invoked standalone, recommend:

```
/idd-issue [bug] add manual macOS 26 verification test (TCC dialog appears, permissions persist)
```

so the human verification step has a tracking issue.

## Templates (in templates/)

- `Entitlements.plist` — empty `<dict/>` plist
- `sign-and-notarize.sh` — full script (verbatim from che-ical-mcp PR #44 c2d0db5; env-var driven, no hardcoded identity)
- `build-script-step-3.5.sh` — bash snippet to insert into build-mcpb.sh / build-cli.sh
- `Makefile-release-signed.snippet` — Make target snippet
- `README-signing-section.md` — README subsection with `{{TARGET_NAME}}` placeholders
- `changelog-distribution.md` — CHANGELOG entry snippet

## Iron rules

- **Never hardcode `DEVELOPER_ID` default**. Always require it via env var. The c-ical-mcp Round 1 vs Round 2 verify caught this exact regression.
- **Always inject `REQUIRE_CODESIGN=1` in `make release-signed`** so canonical release path fails fast if env unset (Codex P1 finding from che-ical-mcp Round 2).
- **Always install `rm -f` in `install:` target** (#62 inode-cache trap fix; affects 100% of upgrade users).
- **Always recommend manual macOS 26 test** as a follow-up. spctl + codesign passing does NOT mean TCC dialog actually appears — that's a separate Apple gate.
- **Skill never installs cert / notarytool profile**. Those are user-side prereqs. Install scripts emit friendly errors if missing.

## Provenance

Templates extracted from `che-ical-mcp` PR #52 (2026-05-04, squash `f04fdf8`):
- 4 commits via 3 rounds of cross-model verify (5 Claude reviewers + Codex gpt-5.5)
- Round 2 caught silent-degrade antipattern (Codex P1 + Devil's Advocate P2 cross-confirmed)
- End-to-end verified on macOS 26.4.1: `spctl -t install` returns `accepted`, `--setup` grants Calendar + Reminders, real EventKit calls succeed

This is the productionized template, not a draft.

## Next step suggestions

After applying:
- `/idd-issue` — file follow-up for manual macOS 26 verification gate
- `/idd-issue` — file follow-up for GitHub Actions CI signing (deferred from MVP)
- Manual: `make release-signed && install + verify on macOS 26 hardware`
