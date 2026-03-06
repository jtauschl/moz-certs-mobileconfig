#!/bin/bash
#
# generate.sh – Mozilla Root Certificates mobileconfig Generator
#
# Downloads cacert.pem from curl.se, generates a .mobileconfig profile.
# Skips generation if the SHA-256 of cacert.pem has not changed.
#
# Usage:  ./generate.sh                  # unsigned (no cert required)
#         ./generate.sh -s|--signed      # sign with Apple Developer cert
#         ./generate.sh -f|--force       # skip SHA change check
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Leave empty to auto-detect from Keychain (uses first Developer ID Application cert)
SIGNING_IDENTITY=""

PROFILE_IDENTIFIER="de.tauschl.moz-certs"
PROFILE_NAME="Mozilla Root Certificates"

CACERT_URL="https://curl.se/ca/cacert.pem"
SHA_URL="https://curl.se/ca/cacert.pem.sha256"

OUT_DIR="$(cd "$(dirname "$0")" && pwd)/dist"
OUT_PROFILE="${OUT_DIR}/moz-certs.mobileconfig"

# ============================================================================
# Helpers
# ============================================================================

info()  { echo "  ✓  $*"; }
step()  { echo "  →  $*"; }
die()   { echo "  ✗  $*" >&2; exit 1; }

# ============================================================================
# Main
# ============================================================================

FORCE=false
SIGN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)  FORCE=true ;;
        -s|--signed) SIGN=true ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

echo ""
echo "  moz-certs · mobileconfig generator"
echo ""

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -- Resolve signing identity (only when --signed) ---------------------------
if [[ "$SIGN" == true ]]; then
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -E "Developer ID Application|Apple Development" \
            | head -1 \
            | awk -F'"' '{print $2}')"
        [[ -n "$SIGNING_IDENTITY" ]] \
            || die "No signing certificate found in Keychain (Developer ID Application or Apple Development)"
    fi
    info "Signing with: ${SIGNING_IDENTITY}"
else
    info "Mode: unsigned (use -s to sign)"
fi

# -- Check remote SHA --------------------------------------------------------
step "Checking curl.se for updates..."
REMOTE_SHA="$(curl -fsSL --max-time 10 "$SHA_URL" | awk '{print $1}')" \
    || die "Could not fetch SHA-256 from curl.se"

[[ "${#REMOTE_SHA}" -eq 64 ]] || die "Unexpected SHA-256 format: ${REMOTE_SHA}"
info "Remote SHA-256: ${REMOTE_SHA:0:16}…"

# -- Compare with installed mobileconfig ------------------------------------
if [[ "$FORCE" == false ]] && [[ -f "$OUT_PROFILE" ]]; then
    # Try signed (DER) first, fall back to unsigned (plain XML)
    INSTALLED_SHA="$(openssl smime -verify -in "$OUT_PROFILE" -inform DER -noverify 2>/dev/null \
        | grep -o 'sha256:[a-f0-9]*' | head -1 | sed 's/sha256://')"
    if [[ -z "$INSTALLED_SHA" ]]; then
        INSTALLED_SHA="$(grep -o 'sha256:[a-f0-9]*' "$OUT_PROFILE" | head -1 | sed 's/sha256://')"
    fi
    if [[ "$INSTALLED_SHA" == "$REMOTE_SHA" ]]; then
        info "Already up to date. Nothing to do."
        echo ""
        exit 0
    fi
fi

# -- Download cacert.pem -----------------------------------------------------
step "Downloading cacert.pem..."
CACERT="${WORK}/cacert.pem"
curl -fsSL --max-time 60 -o "$CACERT" "$CACERT_URL" \
    || die "Download failed"

CERT_COUNT="$(grep -c 'BEGIN CERTIFICATE' "$CACERT")"
info "Downloaded ${CERT_COUNT} certificates"

# -- Verify SHA --------------------------------------------------------------
ACTUAL_SHA="$(shasum -a 256 "$CACERT" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$REMOTE_SHA" ]] || die "SHA-256 mismatch – aborting"
info "SHA-256 verified"

# -- Generate mobileconfig ---------------------------------------------------
step "Generating mobileconfig..."
UNSIGNED="${WORK}/unsigned.mobileconfig"

python3 - "$CACERT" "$UNSIGNED" "$PROFILE_IDENTIFIER" "$PROFILE_NAME" "$REMOTE_SHA" <<'PYEOF'

import sys, base64, uuid, re, subprocess, tempfile, os

pem_file, out_file, profile_id, profile_name, sha256 = sys.argv[1:]

def sanitize(s, maxlen=64):
    return re.sub(r'[^a-z0-9-]', '_', s.lower()).strip('_')[:maxlen]

def cn_from_der(der):
    """Extract a human-readable name from DER cert via openssl."""
    try:
        with tempfile.NamedTemporaryFile(suffix=".der", delete=False) as f:
            f.write(der); tmp = f.name
        r = subprocess.run(
            ["openssl", "x509", "-inform", "DER", "-noout",
             "-subject", "-nameopt", "RFC2253", "-in", tmp],
            capture_output=True, text=True, timeout=5
        )
        os.unlink(tmp)
        # RFC2253 output: "subject=CN=Name,O=Org,C=US"
        # Values may contain backslash-escaped commas: O=Entrust\, Inc.
        rdn = r'((?:[^\\,]|\\.)+)'
        m = re.search(r'CN=' + rdn, r.stdout)
        if not m:
            m = re.search(r'O=' + rdn, r.stdout)
        if m:
            # Unescape RFC2253 backslash sequences (\, → ,  \+ → +  etc.)
            return re.sub(r'\\(.)', r'\1', m.group(1)).strip()
    except Exception:
        pass
    return None

with open(pem_file) as f:
    content = f.read()

certs = []
label, in_cert, pem = None, False, ""
for line in content.splitlines():
    s = line.strip()
    if not in_cert:
        # Priority 1 (highest): "# Label: Name" or '# Label: "Name"'
        # Always overrides lower-priority sources – Label appears AFTER Issuer in file
        if s.startswith("# Label:"):
            val = s[len("# Label:"):].strip().strip('"').strip("'")
            if val:
                label = val
        # Priority 2: CN from Subject (only if no label yet)
        elif s.startswith("# Subject:") and label is None:
            m = re.search(r'CN=([^,\n]+?)(?:\s+[A-Z]+=|$)', s)
            if m:
                label = m.group(1).strip()
        # Priority 3: CN from Issuer (only if no label yet)
        elif s.startswith("# Issuer:") and label is None:
            m = re.search(r'CN=([^,\n]+?)(?:\s+[A-Z]+=|$)', s)
            if m:
                label = m.group(1).strip()
        # Priority 4: plain "# CertName" line (curl.se format, no structured metadata)
        elif s.startswith("# ") and not s.startswith("## ") and label is None:
            candidate = s[2:].strip()
            skip = ("Issuer:", "Subject:", "Label:", "Alias:", "Serial:",
                    "MD5 ", "SHA1 ", "SHA256 ", "Fingerprint")
            if candidate and not any(candidate.startswith(p) for p in skip):
                label = candidate
        elif s == "-----BEGIN CERTIFICATE-----":
            in_cert, pem = True, line + "\n"
    else:
        pem += line + "\n"
        if s == "-----END CERTIFICATE-----":
            in_cert = False
            m = re.search(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.DOTALL)
            if m:
                der = base64.b64decode(m.group(1).replace("\n","").replace("\r",""))
                # Priority 4: openssl fallback if all comment parsing failed
                final_label = label or cn_from_der(der) or "Unknown"
                certs.append((final_label, base64.b64encode(der).decode()))
            label = None

payloads = []
for i, (lbl, b64) in enumerate(certs):
    safe = lbl.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
    sid  = sanitize(lbl) or f"cert_{i:04d}"
    fmt  = "\n\t\t\t".join(b64[j:j+76] for j in range(0, len(b64), 76))
    payloads.append(
        f"\t\t<dict>\n"
        f"\t\t\t<key>PayloadCertificateFileName</key><string>{sid}.cer</string>\n"
        f"\t\t\t<key>PayloadContent</key>\n\t\t\t<data>\n\t\t\t{fmt}\n\t\t\t</data>\n"
        f"\t\t\t<key>PayloadDescription</key><string>{safe}</string>\n"
        f"\t\t\t<key>PayloadDisplayName</key><string>{safe}</string>\n"
        f"\t\t\t<key>PayloadEnabled</key><true/>\n"
        f"\t\t\t<key>PayloadIdentifier</key><string>{profile_id}.{i:04d}.{sid}</string>\n"
        f"\t\t\t<key>PayloadType</key><string>com.apple.security.root</string>\n"
        f"\t\t\t<key>PayloadUUID</key><string>{str(uuid.uuid4()).upper()}</string>\n"
        f"\t\t\t<key>PayloadVersion</key><integer>1</integer>\n"
        f"\t\t</dict>"
    )

xml = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"\n'
    '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0"><dict>\n'
    '\t<key>PayloadContent</key>\n\t<array>\n'
    + "\n".join(payloads) +
    '\n\t</array>\n'
    f'\t<key>PayloadDescription</key><string>Mozilla Root Certificates – https://curl.se/ca&#10;sha256:{sha256}</string>\n'
    f'\t<key>PayloadDisplayName</key><string>{profile_name}</string>\n'
    f'\t<key>PayloadIdentifier</key><string>{profile_id}</string>\n'
    '\t<key>PayloadRemovalDisallowed</key><true/>\n'
    '\t<key>PayloadScope</key><string>System</string>\n'
    '\t<key>PayloadType</key><string>Configuration</string>\n'
    f'\t<key>PayloadUUID</key><string>{str(uuid.uuid4()).upper()}</string>\n'
    '\t<key>PayloadVersion</key><integer>1</integer>\n'
    '</dict></plist>'
)

with open(out_file, "w") as f:
    f.write(xml)

print(f"  ✓  {len(certs)} certificate payloads written")
PYEOF

# -- Sign or copy mobileconfig -----------------------------------------------
if [[ "$SIGN" == true ]]; then
    step "Signing..."
    security cms -S -N "$SIGNING_IDENTITY" \
        -i "$UNSIGNED" \
        -o "$OUT_PROFILE" \
        || die "Signing failed – check SIGNING_IDENTITY and Keychain access"
    info "Signed"
else
    cp "$UNSIGNED" "$OUT_PROFILE"
    info "Unsigned (install will show 'Not Verified' warning)"
fi

# -- Done --------------------------------------------------------------------
echo ""
echo "  ──────────────────────────────────────"
echo "  Output: dist/moz-certs.mobileconfig"
echo "  ──────────────────────────────────────"
echo ""
