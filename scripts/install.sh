#!/bin/sh
set -eu
SOURCE="$HOME/Library/Caches/deltavee/dist/Deltavee.app"
DESTINATION="$HOME/Applications/Deltavee.app"
[ -d "$SOURCE" ] || {
	printf '%s\n' 'Build and sign the bundle first.' >&2
	exit 1
}
/usr/bin/codesign --verify --strict "$SOURCE"
mkdir -p "$HOME/Applications"
# ditto merges directories; remove this app's generated resources first so dropped files do not survive.
rm -rf "$DESTINATION/Contents/Resources/Deltavee_Deltavee.bundle"
rm -f "$DESTINATION/Contents/Resources/Assets.car" "$DESTINATION/Contents/Resources/AppIcon.icns" "$DESTINATION/Contents/Resources/claude-statusline-capture.sh"
/usr/bin/ditto "$SOURCE" "$DESTINATION"
/usr/bin/codesign --verify --strict "$DESTINATION"
# ditto keeps the existing bundle directory's mtime, so Finder and icon caches keep the old icon.
touch "$DESTINATION"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DESTINATION"
printf '%s\n' "$DESTINATION"
