#!/bin/bash
# Keep AWDL (the peer-to-peer Wi-Fi interface behind AirDrop, Universal
# Control, Continuity) DOWN on a receiver Mac.
#
# Why: while awdl0 is active the Wi-Fi radio leaves the infrastructure
# channel for ~100 ms every 524 ms (512 TU, AWDL's availability-window
# period). On a receiver that is a 20 % duty cycle of ~100 ms blackouts, and
# no playout target below ~150 ms survives it. macOS brings awdl0 back up
# whenever something asks for it (a login, a Finder AirDrop window, Universal
# Control on a nearby Mac), so `ifconfig awdl0 down` alone lasts minutes to
# hours. This installs a root LaunchDaemon that re-applies it every second —
# but ONLY while the receiver is playing a stream (it publishes a marker file,
# see StreamingMarker.swift). When nothing is playing the radio is left alone,
# so AirDrop / Universal Control / Sidecar keep working on this Mac; they are
# unavailable only for the minutes a stream is actually running.
#
#   sudo scripts/awdl-guard.sh install
#   sudo scripts/awdl-guard.sh uninstall
#   scripts/awdl-guard.sh status
set -euo pipefail

LABEL="io.syncast.awdl-guard"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
BIN="/usr/local/libexec/synccast-awdl-guard"

status() {
  printf 'awdl0: %s\n' "$(ifconfig awdl0 2>/dev/null | awk '/status:/ {print $2}')"
  if [ -f /tmp/io.syncast.receiver.streaming ]; then
    echo "receiver: streaming (marker present)"
  else
    echo "receiver: not streaming"
  fi
  if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "guard: installed and loaded (${PLIST})"
  else
    echo "guard: not installed"
  fi
}

need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "run with sudo" >&2
    exit 1
  fi
}

install() {
  need_root
  mkdir -p "$(dirname "$BIN")"
  cat > "$BIN" <<'GUARD'
#!/bin/bash
# Runs as root under launchd (io.syncast.awdl-guard). Keeps awdl0 down ONLY
# while the receiver says a stream is playing: it touches
# /tmp/io.syncast.receiver.streaming once a second while streaming and removes
# it when the stream stops (StreamingMarker.swift). A marker older than 10 s is
# stale (the daemon died), and the radio is left alone. When nothing is playing
# nothing is touched, so AirDrop / Universal Control work as usual — macOS
# brings awdl0 back up by itself the moment something asks for it.
MARKER=/tmp/io.syncast.receiver.streaming
while true; do
  if [ -f "$MARKER" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$MARKER" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 10 ] && ifconfig awdl0 2>/dev/null | grep -q 'status: active'; then
      ifconfig awdl0 down 2>/dev/null || true
    fi
  fi
  sleep 1
done
GUARD
  chmod 755 "$BIN"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array><string>${BIN}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
  chown root:wheel "$PLIST" "$BIN"
  chmod 644 "$PLIST"
  launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap system "$PLIST"
  sleep 1
  status
}

uninstall() {
  need_root
  launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
  rm -f "$PLIST" "$BIN"
  ifconfig awdl0 up 2>/dev/null || true
  status
}

case "${1:-status}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  *) echo "usage: $0 install|uninstall|status" >&2; exit 2 ;;
esac
