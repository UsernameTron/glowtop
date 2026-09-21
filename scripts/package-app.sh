#!/bin/bash
# Packaging (SPEC.md §2.8): assemble GlowTop.app from a release build, ad-hoc sign it,
# and install it to ~/Applications. The only out-of-repo write this project makes besides
# ~/Library/Logs/GlowTop/actions.log (SPEC.md §13.7 gate 11).
#
# The install destination is a LITERAL path below, never computed and never an argument —
# this is the only `rm -rf` this project runs outside its own tree, and it gets a guard on
# the target, not a comment about being careful.
#
# Developer ID signing is opt-in via GLOWTOP_SIGN_IDENTITY (SPEC.md §14.11); unset signs
# exactly as it has since phase-05, ad-hoc.
#
#   scripts/package-app.sh [--no-install] [--notarize]
set -u
cd "$(dirname "$0")/.." || exit 1

NO_INSTALL=0
NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --no-install) NO_INSTALL=1 ;;
        --notarize) NOTARIZE=1 ;;
        *) echo "package-app: unknown argument $arg" >&2; exit 1 ;;
    esac
done

BUILD_DIR=build
APP="$BUILD_DIR/GlowTop.app"
ICNS="$BUILD_DIR/GlowTop.icns"
IDENTIFIER=com.glowtop.GlowTop
IDENTITY="${GLOWTOP_SIGN_IDENTITY:--}"

echo "package-app: swift build -c release"
swift build -c release || { echo "package-app: release build failed" >&2; exit 1; }
BIN=.build/release/GlowTopApp
[ -x "$BIN" ] || { echo "package-app: $BIN not produced" >&2; exit 1; }

# Regenerate the icon if it's missing or older than the script that draws it.
if [ ! -f "$ICNS" ] || [ scripts/make-icon.swift -nt "$ICNS" ]; then
    echo "package-app: generating icon"
    mkdir -p "$BUILD_DIR"
    ICON_BIN="$BUILD_DIR/glowtop-icon"
    swiftc -O -o "$ICON_BIN" scripts/make-icon.swift || { echo "package-app: icon script failed to compile" >&2; exit 1; }
    "$ICON_BIN" || { echo "package-app: icon generation failed" >&2; exit 1; }
fi
[ -f "$ICNS" ] || { echo "package-app: $ICNS still missing after generation" >&2; exit 1; }

echo "package-app: assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GlowTopApp" || { echo "package-app: failed to copy $BIN" >&2; exit 1; }
cp "$ICNS" "$APP/Contents/Resources/GlowTop.icns" || { echo "package-app: failed to copy $ICNS" >&2; exit 1; }
cp Resources/Info.plist "$APP/Contents/Info.plist" || { echo "package-app: failed to copy Resources/Info.plist" >&2; exit 1; }
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" || { echo "package-app: Info.plist failed plutil -lint" >&2; exit 1; }

if [ "$IDENTITY" = "-" ]; then
    echo "package-app: signing (ad-hoc)"
    codesign --force --sign - --identifier "$IDENTIFIER" "$APP" || { echo "package-app: signing failed" >&2; exit 1; }
else
    echo "package-app: signing (Developer ID)"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier "$IDENTIFIER" "$APP" || { echo "package-app: signing failed" >&2; exit 1; }
fi
codesign --verify --strict --verbose=2 "$APP" || { echo "package-app: signature failed verification -- not installing" >&2; exit 1; }
codesign -dv "$APP"

if [ "$IDENTITY" != "-" ]; then
    DV_OUTPUT=$(codesign -dv --verbose=2 "$APP" 2>&1)
    echo "$DV_OUTPUT" | grep -q '^Authority=Developer ID Application:' || { echo "package-app: signature missing Developer ID Application authority" >&2; exit 1; }
    echo "$DV_OUTPUT" | grep -q '^TeamIdentifier=not set' && { echo "package-app: signature has no team identifier" >&2; exit 1; }
    echo "$DV_OUTPUT" | grep -q 'flags=0x10000(runtime)' || { echo "package-app: hardened runtime flag missing" >&2; exit 1; }
    ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>&1 | grep -v '^Executable=')
    [ -z "$ENTITLEMENTS" ] || { echo "package-app: unexpected entitlements present: $ENTITLEMENTS" >&2; exit 1; }
fi

if [ "$NOTARIZE" -eq 1 ]; then
    [ "$IDENTITY" != "-" ] || { echo "package-app: --notarize requires GLOWTOP_SIGN_IDENTITY" >&2; exit 1; }
    ZIP="$BUILD_DIR/GlowTop.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP" || { echo "package-app: failed to zip $APP for notarization" >&2; exit 1; }
    echo "package-app: submitting for notarization"
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP" --keychain-profile glowtop-notary --wait 2>&1)
    echo "$SUBMIT_OUTPUT"
    if ! echo "$SUBMIT_OUTPUT" | grep -q 'status: Accepted'; then
        SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | awk '/id:/{print $2; exit}')
        echo "package-app: notarization did not report Accepted -- fetching log for $SUBMISSION_ID" >&2
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile glowtop-notary
        exit 1
    fi
    rm -f "$ZIP"
    xcrun stapler staple "$APP" || { echo "package-app: stapling failed" >&2; exit 1; }
    SPCTL_OUTPUT=$(spctl --assess -vv --type execute "$APP" 2>&1)
    echo "$SPCTL_OUTPUT"
    echo "$SPCTL_OUTPUT" | grep -q ': accepted' || { echo "package-app: spctl did not accept the notarized bundle" >&2; exit 1; }
    echo "$SPCTL_OUTPUT" | grep -q 'source=Notarized Developer ID' || { echo "package-app: spctl did not report a notarized source" >&2; exit 1; }
    xcrun stapler validate "$APP" || { echo "package-app: stapler validate failed" >&2; exit 1; }
fi

if [ "$NO_INSTALL" -eq 1 ]; then
    echo "package-app: --no-install, stopping at $APP"
    exit 0
fi

DEST="$HOME/Applications/GlowTop.app"
case "$DEST" in
    */Applications/GlowTop.app) : ;;
    *) echo "package-app: refusing to install — destination is not */Applications/GlowTop.app" >&2; exit 1 ;;
esac

if [ -e "$DEST" ]; then
    if [ -d "$DEST" ] && [ -x "$DEST/Contents/MacOS/GlowTopApp" ]; then
        rm -rf "$DEST"
    else
        echo "package-app: refusing to remove $DEST — exists but is not a GlowTop.app bundle" >&2
        exit 1
    fi
fi

mkdir -p "$HOME/Applications"
cp -R "$APP" "$DEST" || { echo "package-app: failed to install to $DEST" >&2; exit 1; }

echo "package-app: installed $DEST"
echo "package-app: signature: $(codesign -dv "$DEST" 2>&1 | grep '^Identifier=')"
echo "package-app: size: $(du -sh "$DEST" | cut -f1)"
