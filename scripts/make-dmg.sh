#!/bin/bash
# DMG assembly (SPEC.md §14.11): stage the already-packaged, already-verified GlowTop.app
# beside an /Applications symlink and build a UDZO disk image. Consumes build/GlowTop.app
# as-is — it is never re-signed here; scripts/package-app.sh owns signing the app.
#
# Developer ID signing of the IMAGE is opt-in via GLOWTOP_SIGN_IDENTITY (same variable
# package-app.sh reads); unset produces an ad-hoc image and prints an UNSIGNED banner
# where the spctl assertion would stand (D-21).
#
# The staging directory is a LITERAL path below, guarded by a `case` on that literal —
# the same rule package-app.sh's install-destination removal follows.
#
#   scripts/make-dmg.sh
set -u
cd "$(dirname "$0")/.." || exit 1

APP=build/GlowTop.app
STAGING=build/dmg-staging

[ -d "$APP" ] || { echo "make-dmg: $APP not found -- run scripts/package-app.sh first" >&2; exit 1; }
codesign --verify --strict --verbose=2 "$APP" || { echo "make-dmg: $APP failed signature verification" >&2; exit 1; }

echo "make-dmg: input signature"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^(Signature|Authority|TeamIdentifier)='

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
[ -n "$VERSION" ] || { echo "make-dmg: could not read CFBundleShortVersionString from $APP/Contents/Info.plist" >&2; exit 1; }
DMG="build/GlowTop-$VERSION.dmg"

case "$STAGING" in
    build/dmg-staging) : ;;
    *) echo "make-dmg: refusing to remove -- staging path is not build/dmg-staging" >&2; exit 1 ;;
esac
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/GlowTop.app" || { echo "make-dmg: failed to stage $APP" >&2; exit 1; }
ln -s /Applications "$STAGING/Applications" || { echo "make-dmg: failed to create Applications symlink" >&2; exit 1; }

rm -f "$DMG"
echo "make-dmg: hdiutil create $DMG"
hdiutil create -volname GlowTop -srcfolder "$STAGING" -ov -format UDZO "$DMG" || { echo "make-dmg: hdiutil create failed" >&2; exit 1; }
hdiutil verify "$DMG" || { echo "make-dmg: hdiutil verify failed" >&2; exit 1; }

IDENTITY="${GLOWTOP_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    echo "make-dmg: UNSIGNED — no GLOWTOP_SIGN_IDENTITY; spctl not asserted"
else
    echo "make-dmg: signing image (Developer ID)"
    codesign --sign "$IDENTITY" --timestamp "$DMG" || { echo "make-dmg: image signing failed" >&2; exit 1; }
    echo "make-dmg: submitting image for notarization"
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG" --keychain-profile glowtop-notary --wait 2>&1)
    echo "$SUBMIT_OUTPUT"
    if ! echo "$SUBMIT_OUTPUT" | grep -q 'status: Accepted'; then
        SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | awk '/id:/{print $2; exit}')
        echo "make-dmg: notarization did not report Accepted -- fetching log for $SUBMISSION_ID" >&2
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile glowtop-notary
        exit 1
    fi
    xcrun stapler staple "$DMG" || { echo "make-dmg: stapling failed" >&2; exit 1; }
    SPCTL_OUTPUT=$(spctl --assess -vv --type open --context context:primary-signature "$DMG" 2>&1)
    echo "$SPCTL_OUTPUT"
    echo "$SPCTL_OUTPUT" | grep -q ': accepted' || { echo "make-dmg: spctl did not accept the image" >&2; exit 1; }
fi

( cd build && shasum -a 256 "GlowTop-$VERSION.dmg" > "GlowTop-$VERSION.dmg.sha256" )
echo "make-dmg: $DMG"
cat "$DMG.sha256"
