#!/bin/bash
# /data/timemachine/99-timemachine.sh
#
# Restores Samba + Avahi Time Machine configuration after UDM Pro / USM Pro Max
# firmware updates. Firmware updates wipe apt-installed packages and /etc configs,
# but /data is persistent storage and survives updates.
#
# This script is called via a wrapper in the native Ubiquiti boot hook directory:
#   /usr/lib/ubnt/hooks/system/bootup-bottom/99-timemachine.sh
# That hook directory is read by bootup-bottom-invoke.service on every boot.
#
# The script is self-healing: if the hook wrapper is ever removed, it recreates it.
#
# Setup: see https://github.com/scttfrdmn/udm-pro-timemachine (Step 8)

BACKUP_DIR="/data/timemachine"
HOOK_DIR="/usr/lib/ubnt/hooks/system/bootup-bottom"
HOOK_WRAPPER="${HOOK_DIR}/99-timemachine.sh"
LOG_TAG="timemachine-boot"

log() { logger -t "$LOG_TAG" "$*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ ! -d "$BACKUP_DIR" ]; then
    log "ERROR: $BACKUP_DIR not found — run Step 8 setup first (see README)"
    exit 1
fi

# --- Self-heal: recreate the boot hook wrapper if it was removed ---

if [ ! -f "$HOOK_WRAPPER" ]; then
    log "Boot hook wrapper missing — recreating at $HOOK_WRAPPER"
    mkdir -p "$HOOK_DIR"
    cat > "$HOOK_WRAPPER" << 'EOF'
#!/bin/bash
exec /data/timemachine/99-timemachine.sh "$@"
EOF
    chmod +x "$HOOK_WRAPPER"
    log "Boot hook wrapper recreated"
fi

# --- Install packages if wiped by firmware update ---

if ! command -v smbd &>/dev/null; then
    log "Samba missing — reinstalling after firmware update..."
    apt-get update -qq && apt-get install -y -qq samba
    log "Samba installed"
fi

if ! command -v avahi-daemon &>/dev/null; then
    log "Avahi missing — reinstalling after firmware update..."
    apt-get install -y -qq avahi-daemon
    log "Avahi installed"
fi

# --- Restore Samba config ---

if ! grep -q '\[TimeMachine\]' /etc/samba/smb.conf 2>/dev/null; then
    log "TimeMachine share missing from smb.conf — restoring..."
    cat "$BACKUP_DIR/smb-timemachine.conf" >> /etc/samba/smb.conf
    log "smb.conf restored"
fi

if ! pdbedit -L 2>/dev/null | grep -q '^timemachine:'; then
    log "Samba user 'timemachine' missing — restoring passdb..."
    cp "$BACKUP_DIR/passdb.tdb" /var/lib/samba/private/passdb.tdb
    log "Samba passdb restored"
fi

# --- Restore Avahi config ---

if [ ! -f /etc/avahi/services/smb.service ]; then
    log "Avahi service file missing — restoring..."
    mkdir -p /etc/avahi/services
    cp "$BACKUP_DIR/avahi-smb.service" /etc/avahi/services/smb.service
    log "Avahi service file restored"
fi

# --- Ensure correct permissions ---

chown -R timemachine:timemachine /volume1/timemachine

# --- Start or verify Samba ---

if ! systemctl is-active --quiet smbd; then
    log "Starting Samba..."
    systemctl start smbd nmbd
    log "Samba started"
fi

# --- Start or reload Avahi ---
# Avahi is often already running via socket activation — send HUP to reload
# the service file rather than trying to start a second instance.

AVAHI_PID_FILE="/var/run/avahi-daemon/pid"
if pgrep -x avahi-daemon &>/dev/null; then
    if [ -f "$AVAHI_PID_FILE" ]; then
        kill -HUP "$(cat "$AVAHI_PID_FILE")"
        log "Avahi reloaded"
    fi
else
    systemctl start avahi-daemon
    log "Avahi started"
fi

log "Time Machine boot setup complete"
