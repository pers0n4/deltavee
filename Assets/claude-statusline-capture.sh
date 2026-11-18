#!/bin/sh
# Configure as a Claude Code statusLine command. No credentials or session payload is stored.
exec /usr/bin/python3 -c '
import hashlib, json, math, os, pathlib, subprocess, sys, tempfile, time, unicodedata
payload = sys.stdin.buffer.read()
try:
    obj = json.loads(payload)
    limits = obj.get("rate_limits")
    if isinstance(limits, dict):
        safe = {}
        window = limits.get("seven_day")
        if isinstance(window, dict):
            used = window.get("used_percentage")
            reset = window.get("resets_at")
            if not isinstance(used, bool) and isinstance(used, (int, float)) and math.isfinite(used) and 0 <= used <= 100:
                safe["seven_day"] = {"used_percentage": used}
                if not isinstance(reset, bool) and isinstance(reset, (int, float)) and math.isfinite(reset):
                    safe["seven_day"]["resets_at"] = reset
        if safe:
            directory = unicodedata.normalize("NFC", os.path.abspath(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")))
            key = hashlib.sha256(directory.encode()).hexdigest()[:16]
            root = pathlib.Path.home() / "Library/Application Support/dev.pers0n4.deltavee/statusline"
            root.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix=".capture-", dir=root)
            try:
                with os.fdopen(fd, "w") as stream:
                    json.dump({"observedAt": time.time(), "rateLimits": safe}, stream)
                os.replace(temporary, root / (key + ".json"))
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
except Exception:
    pass  # Never emit input or credential-bearing exception details into a status line.
chain = os.environ.get("DELTAVEE_CHAIN_CMD")
if chain:
    try:
        sys.exit(subprocess.run(chain, input=payload, shell=True).returncode)
    except Exception:
        sys.exit(1)
else:
    print("Deltavee captured")
'
