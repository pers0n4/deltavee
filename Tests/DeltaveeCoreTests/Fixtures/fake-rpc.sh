#!/bin/sh
if [ "${1-}" = --version ]; then
    if [ "${CLAUDE_CONFIG_DIR+x}" = x ]; then exit 1; fi
    printf '%s\n' '2.1.0 (Claude Code)'
    exit 0
fi
read -r initialize
printf '%s\n' '{"id":1,"result":{}}'
read -r initialized
read -r request
case "$CODEX_HOME" in
  */term) trap 'printf term > "$CODEX_HOME/term"; exit 0' TERM ;;
  */kill|*/deadline) trap '' TERM ;;
esac
case "$CODEX_HOME" in
  */deadline) : ;;
  *) printf '%s\n' '{"id":2,"result":{"rateLimits":{"secondary":{"windowDurationMins":10080,"usedPercent":31}}}}' ;;
esac
case "$CODEX_HOME" in
  */noaccount) exit 0 ;;
  */deadline) : ;;
  *)
    read -r account
    printf '%s\n' '{"id":3,"result":{"account":{"type":"chatgpt","email":"fake@example.com"}}}'
    ;;
esac
while read -r remaining; do :; done
printf eof > "$CODEX_HOME/eof"
case "$CODEX_HOME" in
  */natural) exit 0 ;;
esac
while :; do /bin/sleep 0.05; done
