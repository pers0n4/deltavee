#!/bin/sh
set -eu
umask 077
ROOT=$(dirname -- "$0")
ROOT=$(CDPATH='' cd -- "$ROOT/.." && pwd -P)
# shellcheck source=scripts/release-common.sh
. "$ROOT/scripts/release-common.sh"

release_require_tools git gh plutil codesign xcrun ditto spctl shasum unzip zipinfo
release_read_metadata "$DIST_APP"
release_verify_signature "$DIST_APP"
DIST_CODE_HASH="$CODE_HASH"
release_require_source_tag
SOURCE_TAG_OBJECT="$TAG_OBJECT"
RELEASE_APP="$RELEASE_DIR/Deltavee.app"
[ -f "$RELEASE_DIR/notarization.plist" ] || release_fail "No Accepted notarization record exists; finish release:notarize first"
[ "$(plutil -extract status raw -o - "$RELEASE_DIR/notarization.plist" 2>/dev/null)" = Accepted ] || release_fail "The saved notarization is not Accepted; do not publish"
[ ! -e "$RELEASE_DIR/publication-started" ] || release_fail "Publication was already attempted for $TAG. Inspect GitHub and $RELEASE_DIR/github-publish.log before any manual recovery; this command never retries or overwrites a release"
release_verify_signature "$RELEASE_APP"
[ "$CODE_HASH" = "$DIST_CODE_HASH" ] || release_fail "The notarized app differs from the current build; do not publish a stale version/build"
release_verify_ticket "$RELEASE_APP"

CHECK_DIR=$(mktemp -d "$CACHE/releases/.publish-check.XXXXXX")
trap 'rm -rf -- "$CHECK_DIR"' 0
trap 'exit 1' HUP INT TERM
cp "$RELEASE_DIR/$ASSET_NAME" "$CHECK_DIR/$ASSET_NAME" || release_fail "The final release ZIP is missing; finish release:notarize first"
cp "$RELEASE_DIR/$CHECKSUM_NAME" "$CHECK_DIR/$CHECKSUM_NAME" || release_fail "The final release checksum is missing; finish release:notarize first"
release_verify_checksum "$CHECK_DIR/$ASSET_NAME" "$CHECK_DIR/$CHECKSUM_NAME"
ZIP_SHA="$SHA256"
release_sha256 "$CHECK_DIR/$CHECKSUM_NAME"
CHECKSUM_SHA="$SHA256"

# Only the app and ditto's AppleDouble metadata may be extracted. Reject paths
# outside the private staging directory and symlinks before extraction.
unzip -Z1 "$CHECK_DIR/$ASSET_NAME" >"$CHECK_DIR/entries" 2>/dev/null || release_fail "The release ZIP cannot be listed; do not publish it"
if ! LC_ALL=C awk '
	/^\// || /\\/ || /(^|\/)\.\.?($|\/)/ { exit 1 }
	/^Deltavee[.]app(\/|$)/ { next }
	/^__MACOSX\/$/ || /^__MACOSX\/[.]_Deltavee[.]app$/ { next }
	/^__MACOSX\/Deltavee[.]app\// && (/\/$/ || /\/[.]_[^\/]+$/) { next }
	{ exit 1 }
' "$CHECK_DIR/entries"; then
	release_fail "The release ZIP contains unexpected or unsafe paths; do not publish it"
fi
zipinfo -l "$CHECK_DIR/$ASSET_NAME" >"$CHECK_DIR/modes" 2>/dev/null || release_fail "The release ZIP metadata cannot be inspected"
LC_ALL=C awk 'substr($1, 1, 1) == "l" { exit 1 }' "$CHECK_DIR/modes" || release_fail "The release ZIP unexpectedly contains symbolic links; do not publish it"
ditto -x -k "$CHECK_DIR/$ASSET_NAME" "$CHECK_DIR/unpacked" >"$CHECK_DIR/extraction.log" 2>&1 || release_fail "The release ZIP cannot be extracted safely; do not publish it"
UNPACKED_APP="$CHECK_DIR/unpacked/Deltavee.app"
release_verify_signature "$UNPACKED_APP"
[ "$CODE_HASH" = "$DIST_CODE_HASH" ] || release_fail "The packaged app does not match the current signed build; do not publish it"
diff -qr "$RELEASE_APP" "$UNPACKED_APP" >/dev/null 2>&1 || release_fail "The ZIP does not contain exactly the current notarized app; do not publish it"
release_verify_ticket "$UNPACKED_APP"

# Fixed-host GETs and exact tag-object comparison prevent implicit repository or
# tag creation. GitHub refs/releases contracts verified 2026-11-18.
# https://docs.github.com/en/rest/git/refs#get-a-reference
# https://docs.github.com/en/rest/releases/releases
github_read() {
	gh api --hostname github.com --method GET --header 'Accept: application/vnd.github+json' --header 'X-GitHub-Api-Version: 2026-03-10' "$@"
}
GH_PROMPT_DISABLED=1
export GH_PROMPT_DISABLED
if ! github_read "repos/$RELEASE_REPOSITORY/git/ref/tags/$TAG" >"$CHECK_DIR/remote-tag.json" 2>"$RELEASE_DIR/github-read.log"; then
	release_fail "Cannot read the existing $TAG tag in github.com/$RELEASE_REPOSITORY; authenticate gh, create the approved repository if needed, and push the exact source tag manually first"
fi
[ "$(plutil -extract ref raw -o - "$CHECK_DIR/remote-tag.json" 2>/dev/null)" = "refs/tags/$TAG" ] || release_fail "GitHub returned an unexpected tag reference"
[ "$(plutil -extract object.sha raw -o - "$CHECK_DIR/remote-tag.json" 2>/dev/null)" = "$TAG_OBJECT" ] &&
	[ "$(plutil -extract object.type raw -o - "$CHECK_DIR/remote-tag.json" 2>/dev/null)" = "$TAG_TYPE" ] || release_fail "The GitHub tag differs from the exact local source tag; do not move or overwrite it"
if ! github_read --paginate "repos/$RELEASE_REPOSITORY/releases?per_page=100" --jq '.[].tag_name' >"$CHECK_DIR/release-tags" 2>>"$RELEASE_DIR/github-read.log"; then
	release_fail "Could not check existing GitHub Releases; no publication was attempted"
fi
if grep -Fqx "$TAG" "$CHECK_DIR/release-tags"; then
	release_fail "A published or draft GitHub Release already uses $TAG; it will not be overwritten"
fi

# Recheck source and current app immediately before the only external write.
release_verify_signature "$DIST_APP"
[ "$CODE_HASH" = "$DIST_CODE_HASH" ] || release_fail "The current app changed during publication preparation; nothing was published"
release_require_source_tag
[ "$TAG_OBJECT" = "$SOURCE_TAG_OBJECT" ] || release_fail "The local tag changed during publication preparation; nothing was published"
if ! (
	set -C
	: >"$RELEASE_DIR/publication-started"
) 2>/dev/null; then
	release_fail "Another publication attempt already started; inspect GitHub rather than retrying"
fi
printf '%s\n' "$TAG" "$TAG_OBJECT" "$ZIP_SHA" >"$RELEASE_DIR/publication-started"
# --verify-tag forbids gh's default automatic tag creation. With assets, gh may
# create a draft and partially upload before failing; never retry automatically.
# https://cli.github.com/manual/gh_release_create (verified 2026-11-18)
if ! gh release create "$TAG" "$CHECK_DIR/$ASSET_NAME" "$CHECK_DIR/$CHECKSUM_NAME" --repo "github.com/$RELEASE_REPOSITORY" --verify-tag --title "Deltavee $VERSION" --notes-from-tag --latest >"$RELEASE_DIR/github-publish.log" 2>&1; then
	release_fail "GitHub publication did not finish successfully and may have created a partial draft/release. Inspect https://github.com/$RELEASE_REPOSITORY/releases and $RELEASE_DIR/github-publish.log; do not rerun blindly"
fi

# GitHub reports SHA-256 digests for uploaded assets. Null/missing digests are
# unverified, not success; inspect the existing release without creating another.
# https://docs.github.com/en/rest/releases/releases (verified 2026-11-18)
QUERY="[.tag_name == \"$TAG\", .draft == false, .prerelease == false, (.assets | length == 2), ([.assets[] | select(.name == \"$ASSET_NAME\" and .state == \"uploaded\" and .digest == \"sha256:$ZIP_SHA\")] | length == 1), ([.assets[] | select(.name == \"$CHECKSUM_NAME\" and .state == \"uploaded\" and .digest == \"sha256:$CHECKSUM_SHA\")] | length == 1)] | all"
if ! github_read "repos/$RELEASE_REPOSITORY/releases/tags/$TAG" --jq "$QUERY" >"$RELEASE_DIR/github-verification.log" 2>>"$RELEASE_DIR/github-read.log"; then
	release_fail "A release was created but could not be verified; inspect the existing GitHub Release manually without rerunning publication"
fi
[ "$(cat "$RELEASE_DIR/github-verification.log")" = true ] || release_fail "The created release or uploaded asset digests do not match; inspect it manually without retrying or overwriting"
if ! github_read "repos/$RELEASE_REPOSITORY/git/ref/tags/$TAG" --jq '.object.sha' >"$CHECK_DIR/published-tag" 2>>"$RELEASE_DIR/github-read.log"; then
	release_fail "The release was created, but its source tag could not be rechecked; inspect it manually without retrying"
fi
[ "$(cat "$CHECK_DIR/published-tag")" = "$TAG_OBJECT" ] || release_fail "The source tag moved during publication; inspect the created release manually without overwriting it"
printf '%s\n' "https://github.com/$RELEASE_REPOSITORY/releases/tag/$TAG"
