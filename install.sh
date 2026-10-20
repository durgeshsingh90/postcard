#!/usr/bin/env bash
# Builds Postcard, installs it for the current user and registers a LaunchAgent that keeps
# `postcard --watch` running: it checks for a new photo at login, hourly and on wake, and applies the
# image to each Space and display (including Sidecar) as you switch to it.
# No sudo needed. Re-run any time to upgrade.
set -euo pipefail

LABEL="local.postcard"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/Postcard"
BIN_DIR="$SUPPORT/bin"
BIN="$BIN_DIR/postcard"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Postcard"
INTERVAL="${POSTCARD_INTERVAL:-3600}"   # seconds between checks (skipped once today's image is applied)
DOMAIN="gui/$(id -u)"

"$ROOT/build.sh"

mkdir -p "$BIN_DIR" "$AGENTS" "$LOG_DIR"
install -m 0755 "$ROOT/build/postcard" "$BIN.new"
mv -f "$BIN.new" "$BIN"

# Convenience symlink on PATH if a user-writable bin dir exists (Homebrew's usually is).
for d in /opt/homebrew/bin /usr/local/bin; do
  if [[ -d "$d" && -w "$d" ]]; then ln -sf "$BIN" "$d/postcard"; echo "Linked $d/postcard"; break; fi
done

cat > "$PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--watch</string>
    <string>--interval</string>
    <string>$INTERVAL</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Background</string>
  <key>Nice</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST.new" >/dev/null
mv -f "$PLIST.new" "$PLIST"

# Apply today's image now, in the foreground, so you see the result immediately.
echo "Fetching today's image..."
"$BIN" || echo "First run failed (see $LOG_DIR/postcard.log); the agent will retry."

# (Re)register the agent.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the old process has exited; bootstrapping too soon fails with error 5.
for _ in {1..20}; do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done
launchctl bootstrap "$DOMAIN" "$PLIST" || { sleep 2; launchctl bootstrap "$DOMAIN" "$PLIST"; }
launchctl enable "$DOMAIN/$LABEL"

echo
echo "Postcard installed. Checking for a new photo every $((INTERVAL / 60)) min (until today's image is applied),"
echo "at login and after wake, and applying it to each Space and display as you switch to it."
echo "  Status:     $BIN --status"
echo "  Force:      $BIN --force"
echo "  Log:        $LOG_DIR/postcard.log"
echo "  Uninstall:  $ROOT/uninstall.sh"
