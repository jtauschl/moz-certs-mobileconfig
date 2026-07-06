#!/bin/bash
#
# smoke.sh – reproducible invariant checks for generate.sh
#
# Exercises the download/count/payload path via local file:// fixtures,
# without touching the network. Run from the repo root or anywhere:
#     bash test/smoke.sh
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="${REPO}/test/fixtures"
GEN="${REPO}/generate.sh"
PROFILE="${REPO}/dist/moz-certs.mobileconfig"

# -- Artefact isolation ------------------------------------------------------
# generate.sh always writes to dist/moz-certs.mobileconfig. Preserve any
# existing working artefact and restore it on exit; drop dist/ if we created it.
BACKUP=""
DIST_EXISTED=false
[[ -d "${REPO}/dist" ]] && DIST_EXISTED=true
if [[ -f "$PROFILE" ]]; then
    BACKUP="$(mktemp)"
    cp "$PROFILE" "$BACKUP"
fi
cleanup() {
    if [[ -n "$BACKUP" ]]; then
        mkdir -p "${REPO}/dist"
        mv "$BACKUP" "$PROFILE"
    else
        rm -f "$PROFILE"
    fi
    [[ "$DIST_EXISTED" == false ]] && rmdir "${REPO}/dist" 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "  ✓  $1"; }
fail() { echo "  ✗  $1" >&2; exit 1; }

# Run generate.sh --force with the given fixture; returns its exit code.
run_gen() {
    local base="$1"
    CACERT_URL="file://${FIXTURES}/${base}.pem" \
    SHA_URL="file://${FIXTURES}/${base}.pem.sha256" \
        bash "$GEN" --force >/dev/null 2>&1
}

echo "smoke.sh – generate.sh invariants"

# -- 1. Valid bundle (>=100 certs) succeeds and writes a valid profile -------
if run_gen valid; then
    pass "valid bundle: generate.sh succeeded"
else
    fail "valid bundle: generate.sh unexpectedly failed"
fi

[[ -f "$PROFILE" ]] || fail "valid bundle: no profile written"

PAYLOADS=$(grep -c '<key>PayloadCertificateFileName</key>' "$PROFILE")
CERT_COUNT=$(grep -c 'BEGIN CERTIFICATE' "${FIXTURES}/valid.pem")
[[ "$PAYLOADS" -eq "$CERT_COUNT" ]] \
    || fail "payload count ${PAYLOADS} != cert count ${CERT_COUNT}"
[[ "$PAYLOADS" -ge 100 ]] || fail "payload count ${PAYLOADS} < 100"
pass "valid bundle: ${PAYLOADS} payloads == ${CERT_COUNT} certs (>=100)"

# Plist validity via plistlib (portable; plutil is macOS-only).
python3 - "$PROFILE" <<'PY' || fail "valid bundle: plist did not parse"
import plistlib, sys
plistlib.load(open(sys.argv[1], "rb"))
PY
pass "valid bundle: plist parses"

# -- 2. Small bundle (<100 certs) aborts -------------------------------------
if run_gen small; then
    fail "small bundle: generate.sh should have aborted but succeeded"
else
    pass "small bundle: generate.sh aborted as expected"
fi

# -- 3. Empty bundle (0 certs) aborts with the min-count message -------------
EMPTY_OUT="$(CACERT_URL="file://${FIXTURES}/empty.pem" \
             SHA_URL="file://${FIXTURES}/empty.pem.sha256" \
             bash "$GEN" --force 2>&1 || true)"
if grep -q 'Only 0 certificates found' <<<"$EMPTY_OUT"; then
    pass "empty bundle: aborted via min-count check"
else
    fail "empty bundle: expected 'Only 0 certificates found', got: ${EMPTY_OUT}"
fi

# -- 4. Invalid SHA (not 64 hex) aborts --------------------------------------
BADSHA="$(mktemp)"
echo "not-a-valid-sha" > "$BADSHA"
if CACERT_URL="file://${FIXTURES}/valid.pem" SHA_URL="file://${BADSHA}" \
       bash "$GEN" --force >/dev/null 2>&1; then
    rm -f "$BADSHA"
    fail "invalid SHA: generate.sh should have aborted but succeeded"
else
    rm -f "$BADSHA"
    pass "invalid SHA: generate.sh aborted as expected"
fi

echo "All smoke checks passed."
