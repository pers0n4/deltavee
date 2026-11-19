#!/bin/sh
set -eu
SIGN_IDENTITY="${SIGN_IDENTITY:--}" # ad-hoc by default
ROOT=$(dirname -- "$0")
ROOT=$(CDPATH='' cd -- "$ROOT/.." && pwd -P)
# shellcheck source=scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"
APP_VERSION="${APP_VERSION-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER-1}"
release_validate_version "$APP_VERSION" "$BUILD_NUMBER"
SOURCE_REVISION=$(release_clean_source_revision || :)
APP="$DIST_APP"
swift build --package-path "$ROOT" --scratch-path "$CACHE/build" -c release
BIN=$(swift build --package-path "$ROOT" --scratch-path "$CACHE/build" -c release --show-bin-path)
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Deltavee" "$APP/Contents/MacOS/Deltavee"
# Strip the packaged copy's debug map; keep the original build output for debugging.
xcrun strip -S "$APP/Contents/MacOS/Deltavee"
release_verify_binary_paths "$APP/Contents/MacOS/Deltavee"
mkdir -p "$APP/Contents/Resources"
# Replace generated resources so removed assets (such as the color PNGs) are not retained.
rm -rf "$APP/Contents/Resources/Deltavee_Deltavee.bundle"
cp -R "$BIN/Deltavee_Deltavee.bundle" "$APP/Contents/Resources/"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' >"$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string dev.pers0n4.deltavee "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string Deltavee "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string Deltavee "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/bin/plutil -insert DeltaveeUpdateRepository -string "$RELEASE_REPOSITORY" "$APP/Contents/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 26.0 "$APP/Contents/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool YES "$APP/Contents/Info.plist"
# Compile the Icon Composer app icon into Assets.car (macOS 26+ only; no .icns is shipped).
ICON_PLIST="$CACHE/AppIcon-partial.plist"
rm -f "$APP/Contents/Resources/Assets.car" "$APP/Contents/Resources/AppIcon.icns" "$ICON_PLIST"
if ! ACTOOL_LOG=$(xcrun actool "$ROOT/Assets/AppIcon.icon" --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$ICON_PLIST" --errors --warnings --output-format human-readable-text 2>&1); then
	printf '%s\n' "$ACTOOL_LOG" >&2
	exit 1
fi
case "$ACTOOL_LOG" in *'.warnings */'* | *'.errors */'*) printf '%s\n' "$ACTOOL_LOG" >&2 ;; esac
rm -f "$APP/Contents/Resources/AppIcon.icns"
if [ ! -f "$APP/Contents/Resources/Assets.car" ]; then
	echo "bundle.sh: actool did not produce Assets.car" >&2
	exit 1
fi
ICON_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$ICON_PLIST")
if [ -z "$ICON_NAME" ]; then
	echo "bundle.sh: actool did not report CFBundleIconName" >&2
	exit 1
fi
/usr/bin/plutil -insert CFBundleIconName -string "$ICON_NAME" "$APP/Contents/Info.plist"
# Ship the hook so the app can install or refresh it at launch.
cp "$ROOT/Assets/claude-statusline-capture.sh" "$APP/Contents/Resources/claude-statusline-capture.sh"
chmod 755 "$APP/Contents/Resources/claude-statusline-capture.sh"
# A dirty or changing checkout remains buildable locally, but is not a release candidate.
if [ -n "$SOURCE_REVISION" ] && [ "$(release_clean_source_revision || :)" = "$SOURCE_REVISION" ]; then
	/usr/bin/plutil -insert DeltaveeSourceRevision -string "$SOURCE_REVISION" "$APP/Contents/Info.plist"
fi
SIGNING_LOG="$CACHE/codesign.log"
(umask 077 && : >"$SIGNING_LOG")
chmod 600 "$SIGNING_LOG"
if [ "$SIGN_IDENTITY" = - ]; then
	set -- --force --options runtime --sign "$SIGN_IDENTITY"
else
	# Apple requires a secure timestamp for notarization; verified 2026-11-18.
	# https://developer.apple.com/documentation/security/resolving-common-notarization-issues
	set -- --force --options runtime --timestamp --sign "$SIGN_IDENTITY"
fi
if ! /usr/bin/codesign "$@" "$APP" >"$SIGNING_LOG" 2>&1; then
	release_fail "Signing failed; inspect $SIGNING_LOG locally (it may contain certificate details)"
fi
printf '%s\n' "$APP"
