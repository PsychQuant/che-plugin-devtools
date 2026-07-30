# Step 3.5: Sign + notarize for distribution.
# Required for releases: macOS 26 TCC rejects ad-hoc binaries; Developer ID
# signing + hardened runtime + notarization is the only way Calendar/Reminders/
# AppleEvents permission dialogs appear for end users.
#
# Behavior:
#   SKIP_CODESIGN=1 (or "true") → skip unconditionally (local iteration override)
#   REQUIRE_CODESIGN=1 → fail-fast if signing prerequisites missing
#     (used by `make release-signed` — canonical release path must not
#      silently produce unsigned artifacts)
#   No DEVELOPER_ID env or no cert in keychain → auto-skip with warning
#     (default fork-friendly behavior for direct script invocation)
#   Otherwise → run sign-and-notarize.sh
echo ""
SHOULD_SIGN=true
SKIP_REASON=""
if [[ "${SKIP_CODESIGN:-}" == "1" || "${SKIP_CODESIGN:-}" == "true" ]]; then
    SHOULD_SIGN=false
    SKIP_REASON="SKIP_CODESIGN=$SKIP_CODESIGN"
elif [[ -z "${DEVELOPER_ID:-}" ]]; then
    SHOULD_SIGN=false
    SKIP_REASON="DEVELOPER_ID env not set"
elif ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    SHOULD_SIGN=false
    SKIP_REASON="codesigning identity '$DEVELOPER_ID' not in keychain"
fi

if [[ "$SHOULD_SIGN" == "false" ]]; then
    if [[ "${REQUIRE_CODESIGN:-}" == "1" || "${REQUIRE_CODESIGN:-}" == "true" ]]; then
        # Canonical release path — refuse to produce unsigned artifact silently
        echo "[3.5/N] ✗ Refusing to skip signing: REQUIRE_CODESIGN=$REQUIRE_CODESIGN" >&2
        echo "        Reason: $SKIP_REASON" >&2
        echo "        Fix: set DEVELOPER_ID + NOTARY_PROFILE, install Developer ID Application" >&2
        echo "             cert, and ensure cert is in your login keychain." >&2
        echo "        See README 'Signing & Notarization' for one-time setup." >&2
        exit 1
    fi
    # Fork-friendly auto-skip: warn + continue with unsigned binary
    echo "[3.5/N] Skipping codesign + notarize."
    echo "  Reason: $SKIP_REASON"
    echo "  ⚠ Resulting binary is ad-hoc signed; suitable for local dev only."
    echo "  ⚠ To produce a release-quality artifact on macOS 26: set DEVELOPER_ID +"
    echo "    NOTARY_PROFILE, install Developer ID Application cert, then run \`make release-signed\`."
else
    echo "[3.5/N] Signing + notarizing for distribution..."
    "$SCRIPT_DIR/sign-and-notarize.sh" "$UNIVERSAL_BINARY"
fi
