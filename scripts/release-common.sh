#!/bin/sh
# Shared by the explicit manual release commands and bundle.sh.
RELEASE_REPOSITORY=pers0n4/deltavee
CACHE="$HOME/Library/Caches/deltavee"
DIST_APP="$CACHE/dist/Deltavee.app"
# Output variables form this sourced helper's interface to the release command scripts.
export DIST_APP RELEASE_DIR CHECKSUM_NAME TAG_TYPE

release_fail() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

release_require_tools() {
	for TOOL in "$@"; do
		command -v "$TOOL" >/dev/null 2>&1 || release_fail "Required tool missing: $TOOL; install the documented release prerequisites"
	done
}

release_validate_version() {
	printf '%s\n' "$1" | LC_ALL=C grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
		release_fail "APP_VERSION must be stable SemVer X.Y.Z without leading zeroes or a v prefix"
	case "$2" in
	"" | 0* | *[!0-9]*) release_fail "BUILD_NUMBER must be a positive integer without leading zeroes; increment it for every release build" ;;
	esac
}

release_verify_binary_paths() {
	[ -f "$1" ] && [ -r "$1" ] || release_fail "Could not read the executable for its privacy check"
	if LC_ALL=C grep -aEq '/(Users|home)/' "$1"; then
		release_fail "The executable contains an absolute user-home path; remove machine-specific resource accessors before distributing it"
	else
		[ "$?" -eq 1 ] || release_fail "Could not inspect executable paths"
	fi
}

release_clean_source_revision() {
	[ "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$ROOT" ] || return 1
	SOURCE_STATE=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=normal 2>/dev/null) || return 1
	[ -z "$SOURCE_STATE" ] || return 1
	git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null
}

release_read_metadata() {
	[ -d "$1" ] || release_fail "Build the app first with APP_VERSION=X.Y.Z BUILD_NUMBER=N mise run build:release"
	INFO="$1/Contents/Info.plist"
	VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$INFO" 2>/dev/null) || release_fail "The app is missing CFBundleShortVersionString; rebuild it"
	BUILD=$(plutil -extract CFBundleVersion raw -o - "$INFO" 2>/dev/null) || release_fail "The app is missing CFBundleVersion; rebuild it"
	release_validate_version "$VERSION" "$BUILD"
	[ "$(plutil -extract CFBundleIdentifier raw -o - "$INFO" 2>/dev/null)" = dev.pers0n4.deltavee ] || release_fail "Unexpected app bundle identifier"
	[ "$(plutil -extract DeltaveeUpdateRepository raw -o - "$INFO" 2>/dev/null)" = "$RELEASE_REPOSITORY" ] || release_fail "The app does not name the approved update repository; rebuild it"
	REVISION=$(plutil -extract DeltaveeSourceRevision raw -o - "$INFO" 2>/dev/null) || release_fail "No clean source revision was recorded; commit all source changes and rebuild"
	printf '%s\n' "$REVISION" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$' || release_fail "Invalid source revision in the app; rebuild from a clean Git checkout"
	[ "${APP_VERSION-$VERSION}" = "$VERSION" ] || release_fail "APP_VERSION differs from the built app; rebuild or unset the override"
	[ "${BUILD_NUMBER-$BUILD}" = "$BUILD" ] || release_fail "BUILD_NUMBER differs from the built app; rebuild or unset the override"
	RELEASE_DIR="$CACHE/releases/$VERSION-$BUILD"
	ASSET_NAME="Deltavee-$VERSION-$BUILD.zip"
	CHECKSUM_NAME="$ASSET_NAME.sha256"
	TAG="v$VERSION"
}

release_verify_signature() {
	# Developer ID OIDs and -R syntax: Apple TN3127, verified 2026-11-18.
	# https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
	REQUIREMENT='=anchor apple generic and identifier "dev.pers0n4.deltavee" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]'
	codesign --verify --deep --strict --test-requirement "$REQUIREMENT" "$1" >/dev/null 2>&1 ||
		release_fail "The app needs a valid Developer ID Application signature; run mise run build:release with the correct certificate"
	SIGNATURE=$(codesign --display --verbose=4 "$1" 2>&1) || release_fail "Could not inspect the app signature"
	# Apple documents Timestamp (not Signed Time) as the secure timestamp marker.
	# https://developer.apple.com/documentation/security/resolving-common-notarization-issues
	# Verified 2026-11-18.
	printf '%s\n' "$SIGNATURE" | grep -Eq '^Timestamp=.' || release_fail "The app has no secure timestamp; rebuild with mise run build:release"
	printf '%s\n' "$SIGNATURE" | grep -Eq 'flags=.*[(,]runtime[),]' || release_fail "The app does not enable hardened runtime; rebuild it"
	CODE_HASH=$(printf '%s\n' "$SIGNATURE" | awk -F= '$1 == "CDHash" { print $2; exit }')
	printf '%s\n' "$CODE_HASH" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$' || release_fail "Could not read the app code-directory hash"
}

release_require_source_tag() {
	[ "$(release_clean_source_revision)" = "$REVISION" ] || release_fail "The current checkout must be clean and at the app's recorded source revision; rebuild from that commit"
	TAG_COMMIT=$(git -C "$ROOT" rev-parse --verify "refs/tags/$TAG^{commit}" 2>/dev/null) ||
		release_fail "Create the exact local $TAG tag at the clean source commit first; this command never creates or pushes tags"
	[ "$TAG_COMMIT" = "$REVISION" ] || release_fail "The local $TAG tag does not match the app's source revision; do not move an existing release tag"
	TAG_OBJECT=$(git -C "$ROOT" rev-parse --verify "refs/tags/$TAG")
	TAG_TYPE=$(git -C "$ROOT" cat-file -t "$TAG_OBJECT")
}

release_sha256() {
	SHA_LINE=$(shasum -a 256 "$1") || release_fail "Could not compute the artifact SHA-256"
	SHA256=${SHA_LINE%% *}
	printf '%s\n' "$SHA256" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || release_fail "Could not read the artifact SHA-256"
}

release_verify_checksum() {
	[ -f "$1" ] && [ -f "$2" ] || release_fail "The release ZIP or its checksum is missing; finish release:notarize first"
	release_sha256 "$1"
	printf '%s  %s\n' "$SHA256" "${3-$ASSET_NAME}" | cmp -s - "$2" || release_fail "The release ZIP does not match its exact checksum file; do not publish it"
}

release_verify_ticket() {
	# Apple requires stapling the app (not the ZIP); verified 2026-11-18.
	# https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
	xcrun stapler validate -q "$1" >/dev/null 2>&1 || release_fail "The app has no valid stapled notarization ticket; finish release:notarize first"
	spctl --assess --type execute "$1" >/dev/null 2>&1 || release_fail "Gatekeeper assessment failed for the stapled app; do not publish it"
}
