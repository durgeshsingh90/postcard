#!/usr/bin/env bash
# Removes Postcard: the LaunchAgent and binary. With --purge also deletes downloaded images,
# logs and settings. Your current wallpaper is left as it is.
set -euo pipefail

LABEL="com.durgesh.postcard"
SUPPORT="$HOME/Library/Application Support/Postcard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Postcard"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$SUPPORT/bin"
for d in /opt/homebrew/bin /usr/local/bin; do
  if [[ -L "$d/postcard" ]]; then rm -f "$d/postcard"; fi
done

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$SUPPORT" "$LOG_DIR"
  defaults delete "$LABEL" 2>/dev/null || true
  echo "Postcard uninstalled and purged images, logs and settings."
else
  echo "Postcard uninstalled. Images kept in: $SUPPORT/images  (run with --purge to delete them)"
fi
