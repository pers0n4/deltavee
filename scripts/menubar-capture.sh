#!/bin/sh
# Captures every menu bar display case of an installed Deltavee on a light and a dark menu bar.
#
# Each scenario runs as a separate app instance with a fake home (CFFIXED_USER_HOME), so the real
# accounts, snapshots, Keychain, and network are not touched: Claude accounts read statusline files
# only, and Codex accounts run a fake `codex` that answers the app-server request. The menu bar
# shade follows the wallpaper, so the script sets a 0.20 and then a 0.95 gray wallpaper, captures
# the instances' menu bar items, and restores the wallpaper. During each capture a flat gray,
# click-through strip covers the top of the main display, so window shadows do not shade the bar. It sends no keyboard or mouse input.
#
# Usage: sh scripts/menubar-capture.sh [app]   (default: ~/Applications/Deltavee.app)
# DELTAVEE_CAPTURE_BATCH sets how many instances share the menu bar at once (default 4).
# Output: scratch/menubar-capture/menubar.png and menubar.txt (measured contrast) in the repository.
# Intermediate files (helper, fake homes, raw shots) stay in ~/Library/Caches/deltavee/menubar-capture.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
APP=${1:-"$HOME/Applications/Deltavee.app"}
OUT="$ROOT/scratch/menubar-capture"
WORK="$HOME/Library/Caches/deltavee/menubar-capture"
WALLPAPER="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
WAIT_UNLOCK=${DELTAVEE_CAPTURE_WAIT:-600}

[ -x "$APP/Contents/MacOS/Deltavee" ] || {
	echo "No app at $APP" >&2
	exit 1
}

locked() {
	[ "$(ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw -o - - 2>/dev/null)" = true ]
}
waited=0
while locked; do
	[ "$waited" -lt "$WAIT_UNLOCK" ] || {
		echo "The screen stayed locked for ${WAIT_UNLOCK}s." >&2
		exit 1
	}
	[ "$waited" -gt 0 ] || echo "Waiting for the screen to be unlocked..."
	sleep 5
	waited=$((waited + 5))
done

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/shots" "$OUT"
swiftc -O "$ROOT/scripts/menubar-capture.swift" -o "$WORK/helper"

# A fake Codex: answers `initialize` and `account/rateLimits/read` with the percentage stored in
# CODEX_HOME/used (no weekly window for "none"), and fails when the file is missing. Request shape: Sources/DeltaveeCore/Processes.swift.
cat >"$WORK/bin/codex" <<'EOF'
#!/bin/sh
# A read over a stale value: never answer, until the app's timeout or the script ends it.
if [ -e "$CODEX_HOME/hang" ]; then
	while :; do /bin/sleep 1; done
fi
used=$(/bin/cat "$CODEX_HOME/used" 2>/dev/null) || exit 1
resets=$(($(/bin/date +%s) + 259200))
while IFS= read -r line; do
	case $line in
	*'"id":1,'* | *'"id":1}'*) printf '{"id":1,"result":{}}\n' ;;
	*'"id":2,'* | *'"id":2}'*)
		if [ "$used" = none ]; then
			printf '{"id":2,"result":{"rateLimits":{"primary":null,"secondary":null}}}\n'
		else
			printf '{"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":10080,"usedPercent":%s,"resetsAt":%s}}}}\n' "$used" "$resets"
		fi
		exit 0
		;;
	esac
done
EOF
chmod +x "$WORK/bin/codex"
"$WORK/helper" fixtures "$WORK/scenarios" "$WORK/bin/codex" >"$WORK/scenarios.tsv"

# Every Deltavee menu bar item as `pid  x  y  width  height  description` (lines joined by " | ").
items() {
	osascript <<'EOF'
set out to ""
set AppleScript's text item delimiters to " | "
tell application "System Events"
	repeat with p in (every process whose name is "Deltavee")
		-- An instance that is still starting has no menu bar yet; the next poll picks it up.
		try
			repeat with m in (menu bar items of menu bar 1 of p)
				set pos to position of m
				set sz to size of m
				set d to description of m
				set out to out & (unix id of p) & tab & (item 1 of pos) & tab & (item 2 of pos) & tab & (item 1 of sz) & tab & (item 2 of sz) & tab & ((paragraphs of d) as text) & linefeed
			end repeat
		end try
	end repeat
end tell
return out
EOF
}
# Matches each scenario of the current batch to its instance's item: `pid  id  x  y  width  height`.
match() {
	while IFS="$(printf '\t')" read -r id key _; do
		grep -F -- "$key" "$WORK/all.tsv" | head -n 1 | awk -F '\t' -v id="$id" '{print $1 "\t" id "\t" $2 "\t" $3 "\t" $4 "\t" $5}'
	done <"$WORK/batch.tsv"
}
# The right edge of the frontmost app's menus. Status items left of it are hidden behind them.
menus_end() {
	osascript -e 'tell application "System Events" to tell (first process whose frontmost is true)
	set m to last menu bar item of menu bar 1
	return (item 1 of (position of m as list)) + (item 1 of (size of m as list))
end tell' 2>/dev/null || echo 0
}
started_events=0
pgrep -x "System Events" >/dev/null || started_events=1
cp "$WALLPAPER" "$WORK/Index.plist"
wallpaper_changed=0
launched=0
backdrop=
cleanup() {
	status=$?
	[ -z "$backdrop" ] || kill "$backdrop" 2>/dev/null || true
	if [ "$launched" = 1 ]; then
		items >"$WORK/all.tsv" 2>/dev/null || true
		quit_batch
	fi
	if [ "$wallpaper_changed" = 1 ]; then
		cp "$WORK/Index.plist" "$WALLPAPER"
		killall WallpaperAgent 2>/dev/null || true
		sleep 3
		if cmp -s "$WORK/Index.plist" "$WALLPAPER"; then echo "Wallpaper restored."; else
			echo "Wallpaper store differs from the backup at $WORK/Index.plist" >&2
		fi
	fi
	pkill -f "$WORK/bin/codex" 2>/dev/null || true
	[ "$started_events" = 0 ] || osascript -e 'tell application "System Events" to quit' >/dev/null 2>&1 || true
	exit "$status"
}
trap cleanup EXIT INT TERM
quit_batch() {
	[ -s "$WORK/batch.tsv" ] || return 0
	items >"$WORK/all.tsv" 2>/dev/null || true
	match | cut -f1 | while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done
	# Wait until the batch's items leave the menu bar so the next batch has the room.
	tries=0
	while [ "$tries" -lt 20 ] && items 2>/dev/null | grep -q .; do
		items >"$WORK/all.tsv" 2>/dev/null || true
		[ -n "$(match)" ] || break
		tries=$((tries + 1))
		sleep 0.5
	done
	: >"$WORK/batch.tsv"
}

# Accounts of the current batch whose read must still be running: a failure mark means the capture
# came after the app's Codex timeout.
check_pending() {
	cut -f3 "$WORK/batch.tsv" | tr ',' '\n' | while read -r name; do
		[ -n "$name" ] || continue
		part=$(tr '|' '\n' <"$WORK/all.tsv" | grep -F " $name: " || true)
		case $part in
		'' | *'!'*)
			echo "The read of $name finished before the capture; lower DELTAVEE_CAPTURE_BATCH." >&2
			exit 1
			;;
		esac
	done
}

# Each wallpaper shade is set once. The instances run in batches, so the menu bar has room for every
# item next to the real ones; each batch is launched, captured, and quit within a few seconds.
BATCH=${DELTAVEE_CAPTURE_BATCH:-4}
total=$(($(wc -l <"$WORK/scenarios.tsv")))
for shade in dark light; do
	level=0.20
	[ "$shade" = dark ] || level=0.95
	"$WORK/helper" gray "$level" "$WORK/$shade.png"
	wallpaper_changed=1
	osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"$WORK/$shade.png\"" >/dev/null
	"$WORK/helper" backdrop "$level" &
	backdrop=$!
	sleep 5
	first=1
	while [ "$first" -le "$total" ]; do
		sed -n "$first,$((first + BATCH - 1))p" "$WORK/scenarios.tsv" >"$WORK/batch.tsv"
		first=$((first + BATCH))
		launched=1
		while IFS="$(printf '\t')" read -r id _ _; do
			open -n -g --env CFFIXED_USER_HOME="$WORK/scenarios/$id/home" "$APP"
		done <"$WORK/batch.tsv"

		expected=$(($(wc -l <"$WORK/batch.tsv")))
		tries=0
		while :; do
			items >"$WORK/all.tsv"
			match >"$WORK/items.tsv"
			[ "$(($(wc -l <"$WORK/items.tsv")))" -lt "$expected" ] || break
			tries=$((tries + 1))
			[ "$tries" -lt 30 ] || {
				echo "Only $(($(wc -l <"$WORK/items.tsv"))) of $expected instances showed a menu bar item." >&2
				exit 1
			}
			sleep 1
		done
		# Let the first reads finish, then take the final frames.
		sleep 2
		items >"$WORK/all.tsv"
		match >"$WORK/items.tsv"
		awk -F '\t' -v left="$(menus_end)" '$3 < left || $5 <= 0 {bad = 1} END {exit bad}' "$WORK/items.tsv" || {
			echo "Some items are hidden behind the app menus; lower DELTAVEE_CAPTURE_BATCH." >&2
			exit 1
		}
		while IFS="$(printf '\t')" read -r _ id x y w h; do
			screencapture -x -R"$((x - 4)),$y,$((w + 8)),$h" "$WORK/shots/$id-$shade.png"
		done <"$WORK/items.tsv"
		items >"$WORK/all.tsv"
		check_pending
		quit_batch
	done
	kill "$backdrop" 2>/dev/null || true
	backdrop=
done

"$WORK/helper" compose "$WORK/shots" "$OUT/menubar"
echo "$OUT/menubar.png"
