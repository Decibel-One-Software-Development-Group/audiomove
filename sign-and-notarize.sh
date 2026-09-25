#!/bin/bash
#
# Sign, notarize and staple AudioMove.app for distribution.
#
# This is Decibel One tooling, NOT part of the upstream project -- it is
# deliberately left untracked so it never lands in the PR to jfriesne.
#
# Prerequisites (one-time):
#
#   1) A "Developer ID Application" certificate in your login keychain.
#      Check with:  security find-identity -v -p codesigning
#      (A "Developer ID Installer" cert is NOT sufficient -- that one signs
#      .pkg files only.  You need the Application variant to sign a .app.)
#
#   2) A stored notarytool credential profile, created once with:
#        xcrun notarytool store-credentials "AudioMove" \
#            --apple-id "<your-apple-id>" --team-id "F65Q7R99C8"
#      It will prompt for an app-specific password (appleid.apple.com ->
#      Sign-In and Security -> App-Specific Passwords).  Nothing is stored in
#      this script.
#
# Usage:  ./sign-and-notarize.sh [path/to/AudioMove.app] [notary-profile]
#
set -euo pipefail

APP="${1:-audiomove/AudioMove.app}"
PROFILE="${2:-AudioMove}"

[ -d "$APP" ] || { echo "ERROR: no app bundle at '$APP'"; exit 1; }

# --- Find the signing identity -------------------------------------------
# The '|| true' matters: under 'set -e' with pipefail, grep finding nothing
# would abort the script here and swallow the helpful message below.
IDENTITY=$(security find-identity -v -p codesigning \
           | grep "Developer ID Application" | head -1 \
           | sed -E 's/.*"(.*)"/\1/' || true)

if [ -z "$IDENTITY" ]; then
   echo "ERROR: No 'Developer ID Application' certificate found in the keychain."
   echo
   echo "Present identities:"
   security find-identity -v | sed 's/^/   /'
   echo
   echo "If you have one on another Mac, export it there as a .p12"
   echo "(Keychain Access -> right-click the cert -> Export), copy it over,"
   echo "and double-click to import.  Otherwise create one at"
   echo "developer.apple.com under Certificates -> + -> Developer ID Application."
   exit 1
fi

echo "Signing identity: $IDENTITY"
echo "App bundle:       $APP"
echo

# --- Sign inside-out ------------------------------------------------------
# Nested code must be signed before the enclosing bundle, otherwise sealing
# the outer bundle invalidates it.  --options runtime enables the hardened
# runtime, which notarization requires.  Note we deliberately do NOT use
# --deep, which Apple documents as unreliable and has deprecated.
SIGN_FLAGS=(--force --sign "$IDENTITY" --options runtime --timestamp)

echo "==> Signing nested frameworks, plugins and dylibs..."
# Deepest paths first, so children are always signed before their parents.
find "$APP/Contents" \( -name "*.dylib" -o -name "*.so" -o -name "*.framework" \) -print0 \
  | xargs -0 -n1 -I{} echo {} \
  | awk '{print gsub(/\//,"/"), $0}' | sort -rn | cut -d' ' -f2- \
  | while IFS= read -r item; do
       codesign "${SIGN_FLAGS[@]}" "$item" 2>&1 | sed 's/^/    /' || true
    done

echo "==> Signing the app bundle..."
codesign "${SIGN_FLAGS[@]}" "$APP"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP"

# --- Notarize -------------------------------------------------------------
ZIP="$(dirname "$APP")/$(basename "$APP" .app)-notarize.zip"
echo
echo "==> Zipping for submission (ditto preserves bundle symlinks)..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple (this usually takes a few minutes)..."
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait; then
   echo
   echo "Notarization failed.  To see why:"
   echo "   xcrun notarytool history --keychain-profile \"$PROFILE\""
   echo "   xcrun notarytool log <submission-id> --keychain-profile \"$PROFILE\""
   exit 1
fi

echo "==> Stapling the ticket to the bundle..."
xcrun stapler staple "$APP"
rm -f "$ZIP"

# --- Final proof ----------------------------------------------------------
echo
echo "==> Gatekeeper assessment:"
spctl -a -t exec -vvv "$APP" 2>&1 | sed 's/^/    /'
echo
echo "==> Staple validation:"
xcrun stapler validate "$APP" 2>&1 | sed 's/^/    /'
echo
echo "Done.  '$APP' is signed, notarized and stapled."
echo "It will now open on other Macs without a Gatekeeper warning, including"
echo "offline ones (that is what stapling the ticket buys you)."
