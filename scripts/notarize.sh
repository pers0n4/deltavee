#!/bin/sh
set -eu
umask 077
ROOT=$(dirname -- "$0")
ROOT=$(CDPATH='' cd -- "$ROOT/.." && pwd -P)
# shellcheck source=scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

[ -n "${NOTARY_PROFILE:-}" ] || release_fail "Set NOTARY_PROFILE in the ignored .env.production file after running interactive xcrun notarytool store-credentials"
release_require_tools git plutil codesign xcrun ditto spctl shasum
xcrun --find notarytool >/dev/null 2>&1 || release_fail "Select a full Xcode installation that includes notarytool"
release_read_metadata "$DIST_APP"
release_verify_signature "$DIST_APP"
DIST_CODE_HASH="$CODE_HASH"
release_require_source_tag

mkdir -p "$CACHE/releases"
NEW_RELEASE=false
if [ ! -e "$RELEASE_DIR" ]; then
	mkdir "$RELEASE_DIR"
	NEW_RELEASE=true
fi
LOCK="$RELEASE_DIR/.notarize-lock"
mkdir "$LOCK" 2>/dev/null || release_fail "Another notarization run owns $LOCK; if it was interrupted, confirm it stopped before removing only that lock directory"
trap 'rmdir "$LOCK" 2>/dev/null || :' 0
trap 'exit 1' HUP INT TERM

RELEASE_APP="$RELEASE_DIR/Deltavee.app"
SUBMISSION_ZIP="$RELEASE_DIR/submission.zip"
SUBMISSION_CHECKSUM="$SUBMISSION_ZIP.sha256"
SUBMIT_LOG="$RELEASE_DIR/notarytool-submit.log"
ID_FILE="$RELEASE_DIR/submission-id"
STARTED="$RELEASE_DIR/submission-started"
ZIP="$RELEASE_DIR/$ASSET_NAME"
CHECKSUM="$RELEASE_DIR/$CHECKSUM_NAME"

if [ "$NEW_RELEASE" = true ]; then
	ditto "$DIST_APP" "$RELEASE_APP" >"$RELEASE_DIR/packaging.log" 2>&1 || release_fail "Could not stage the app; inspect $RELEASE_DIR/packaging.log"
	release_verify_signature "$RELEASE_APP"
	[ "$CODE_HASH" = "$DIST_CODE_HASH" ] || release_fail "The staged app differs from the current build; do not submit it"
	# Apple supports ditto ZIP submission; staple the app and re-ZIP after acceptance.
	# Verified 2026-11-18 against Apple's customizing-the-notarization-workflow and man ditto.
	# https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
	ditto -c -k --sequesterRsrc --keepParent "$RELEASE_APP" "$SUBMISSION_ZIP" >>"$RELEASE_DIR/packaging.log" 2>&1 || release_fail "Could not create the submission ZIP; inspect $RELEASE_DIR/packaging.log"
	release_sha256 "$SUBMISSION_ZIP"
	printf '%s  submission.zip\n' "$SHA256" >"$SUBMISSION_CHECKSUM"
fi

[ -d "$RELEASE_APP" ] && [ -f "$SUBMISSION_ZIP" ] || release_fail "An incomplete local release directory exists at $RELEASE_DIR; inspect it before removing or rebuilding that version/build"
release_verify_signature "$RELEASE_APP"
[ "$CODE_HASH" = "$DIST_CODE_HASH" ] || release_fail "This version/build directory contains a different app; increment BUILD_NUMBER and rebuild"
release_verify_checksum "$SUBMISSION_ZIP" "$SUBMISSION_CHECKSUM" submission.zip
if [ -f "$ZIP" ] && [ -f "$CHECKSUM" ]; then
	release_fail "Final release assets already exist at $RELEASE_DIR; use release:publish, which revalidates them without overwriting"
fi
[ ! -e "$ZIP" ] && [ ! -e "$CHECKSUM" ] || release_fail "Incomplete final assets exist at $RELEASE_DIR; inspect and remove only the incomplete final ZIP/checksum before rerunning. Keep the saved submission job"

# A sentinel precedes the only submit call. Never re-upload an uncertain submission.
# Normal output preserves the early id even when --wait times out; structured formats
# only emit one update at the end (notarytool help submit, verified 2026-11-18).
if [ ! -e "$STARTED" ]; then
	release_require_source_tag
	: >"$STARTED"
	SUBMIT_OK=true
	if ! LC_ALL=C xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m --output-format normal --no-progress >"$SUBMIT_LOG" 2>&1; then
		SUBMIT_OK=false
	fi
else
	SUBMIT_OK=true
fi

if [ ! -f "$ID_FILE" ] && [ -f "$SUBMIT_LOG" ]; then
	SUBMISSION_ID=$(awk '$1 == "id:" { print $2; exit }' "$SUBMIT_LOG" | tr '[:upper:]' '[:lower:]')
	if printf '%s\n' "$SUBMISSION_ID" | LC_ALL=C grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
		printf '%s\n' "$SUBMISSION_ID" >"$ID_FILE"
	fi
fi
[ -f "$ID_FILE" ] || release_fail "Submission outcome is unknown; no re-upload will occur. Inspect $SUBMIT_LOG and notarytool history, then recover the matching job ID into $ID_FILE before invoking this command again"
SUBMISSION_ID=$(cat "$ID_FILE")
printf '%s\n' "$SUBMISSION_ID" | LC_ALL=C grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || release_fail "The saved notarization job ID is invalid; inspect $ID_FILE locally"
[ "$SUBMIT_OK" = true ] || release_fail "Notarization submission/wait did not finish successfully. Saved job $SUBMISSION_ID in $ID_FILE; invoke release:notarize again to inspect that same job, not re-upload it"

if ! xcrun notarytool info "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" --output-format plist >"$RELEASE_DIR/notarization.plist.new" 2>"$RELEASE_DIR/notarytool-info.log"; then
	release_fail "Could not inspect saved job $SUBMISSION_ID; no new submission was made. Inspect $RELEASE_DIR/notarytool-info.log"
fi
INFO_ID=$(plutil -extract id raw -o - "$RELEASE_DIR/notarization.plist.new" 2>/dev/null | tr '[:upper:]' '[:lower:]')
[ "$INFO_ID" = "$SUBMISSION_ID" ] || release_fail "Notary response does not match the saved job; do not distribute this artifact"
STATUS=$(plutil -extract status raw -o - "$RELEASE_DIR/notarization.plist.new" 2>/dev/null) || release_fail "Notary response is missing a valid status; keep the saved job and inspect it manually"
mv "$RELEASE_DIR/notarization.plist.new" "$RELEASE_DIR/notarization.plist"
if [ "$STATUS" != Accepted ]; then
	release_fail "Saved job $SUBMISSION_ID is not Accepted; use notarytool info/log with that ID. Nothing was stapled or published, and rerunning will only inspect this job"
fi
xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" "$RELEASE_DIR/notary-log.json" >"$RELEASE_DIR/notarytool-log.log" 2>&1 || release_fail "Accepted job $SUBMISSION_ID could not download its log; inspect $RELEASE_DIR/notarytool-log.log and invoke this command again without re-uploading"
xcrun stapler staple -q "$RELEASE_APP" >"$RELEASE_DIR/stapler.log" 2>&1 || release_fail "Stapling failed for Accepted job $SUBMISSION_ID; inspect $RELEASE_DIR/stapler.log and rerun without re-uploading"
release_verify_signature "$RELEASE_APP"
[ "$CODE_HASH" = "$DIST_CODE_HASH" ] || release_fail "The app changed during notarization; do not distribute it"
release_verify_ticket "$RELEASE_APP"
release_require_source_tag

ditto -c -k --sequesterRsrc --keepParent "$RELEASE_APP" "$ZIP.partial" >>"$RELEASE_DIR/packaging.log" 2>&1 || release_fail "Could not package the stapled app; inspect $RELEASE_DIR/packaging.log"
mv "$ZIP.partial" "$ZIP"
release_sha256 "$ZIP"
printf '%s  %s\n' "$SHA256" "$ASSET_NAME" >"$CHECKSUM"
printf '%s\n' "$ZIP" "$CHECKSUM"
