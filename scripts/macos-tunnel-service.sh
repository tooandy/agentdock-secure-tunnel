#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.aniss.agentdock-secure-tunnel"
DOMAIN="gui/$(id -u)"
TEMPLATE="$ROOT_DIR/launchd/$LABEL.plist.template"
RUNTIME_PLIST="$ROOT_DIR/.runtime/$LABEL.plist"
INSTALLED_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
EXECUTABLE="$ROOT_DIR/scripts/AgentDock Secure Tunnel"
LOG_PATH="$HOME/Library/Logs/agentdock-secure-tunnel.log"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_macos() {
  [ "$(uname -s)" = Darwin ] || fail "macOS LaunchAgent management is only available on macOS"
  command -v launchctl >/dev/null 2>&1 || fail "launchctl is required"
  command -v plutil >/dev/null 2>&1 || fail "plutil is required"
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

render_plist() {
  mkdir -p "$ROOT_DIR/.runtime" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  python3 - "$TEMPLATE" "$RUNTIME_PLIST" "$EXECUTABLE" "$ROOT_DIR" "$LOG_PATH" <<'PY'
from pathlib import Path
import sys
src, dst, executable, repo_dir, log_path = sys.argv[1:]
text = Path(src).read_text(encoding='utf-8')
for key, value in {
    '__TUNNEL_EXECUTABLE__': executable,
    '__REPO_DIR__': repo_dir,
    '__LOG_PATH__': log_path,
}.items():
    text = text.replace(key, value)
Path(dst).write_text(text, encoding='utf-8')
PY
  plutil -lint "$RUNTIME_PLIST" >/dev/null
}

install_service() {
  require_macos
  chmod +x "$EXECUTABLE"
  "$ROOT_DIR/agentdock" install
  render_plist
  if is_loaded; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi
  cp "$RUNTIME_PLIST" "$INSTALLED_PLIST"
  chmod 644 "$INSTALLED_PLIST"
  launchctl bootstrap "$DOMAIN" "$INSTALLED_PLIST"
  launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  sleep 2
  status_service
}

start_service() {
  require_macos
  [ -f "$INSTALLED_PLIST" ] || fail "service is not installed; run ./agentdock service-install"
  if ! is_loaded; then launchctl bootstrap "$DOMAIN" "$INSTALLED_PLIST"; fi
  launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  sleep 1
  status_service
}

stop_service() {
  require_macos
  if is_loaded; then launchctl bootout "$DOMAIN/$LABEL"; fi
  printf 'Tunnel LaunchAgent stopped.\n'
}

restart_service() {
  require_macos
  [ -f "$INSTALLED_PLIST" ] || fail "service is not installed; run ./agentdock service-install"
  if is_loaded; then launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true; fi
  launchctl bootstrap "$DOMAIN" "$INSTALLED_PLIST"
  launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  sleep 2
  status_service
}

status_service() {
  require_macos
  if is_loaded; then
    printf 'LaunchAgent : LOADED\n'
    launchctl print "$DOMAIN/$LABEL" | grep -E '^\s*(state|program|pid|last exit code) =' || true
  else
    printf 'LaunchAgent : NOT LOADED\n'
  fi
  "$ROOT_DIR/agentdock" status
}

uninstall_service() {
  require_macos
  if is_loaded; then launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true; fi
  rm -f "$INSTALLED_PLIST" "$RUNTIME_PLIST"
  printf 'Tunnel LaunchAgent uninstalled.\n'
}

case "${1:-status}" in
  install) install_service ;;
  start) start_service ;;
  stop) stop_service ;;
  restart) restart_service ;;
  status) status_service ;;
  uninstall) uninstall_service ;;
  *) fail "usage: $0 {install|start|stop|restart|status|uninstall}" ;;
esac
