#!/bin/bash
# rclone_unmount: add it in the User Scripts plugin with the schedule
# "At Stopping of Array".
#
# Why it exists: Unraid cannot stop the array while the mounts made by
# rclone_mount are still up. It retries "umount /mnt/user", gets "target is
# busy" until the shutdown timer runs out, and then forces an unclean
# shutdown. This script takes the mounts down first. The plugin runs it after
# Docker has been stopped, so nothing is using the mounts any more.

# The mount script. Its "stop" action does the unmounting.
MOUNT_SCRIPT="/boot/config/plugins/user.scripts/scripts/rclone_mount/script"
# How long to wait for rclone and mergerfs to exit before stopping them.
# Keep it well under Unraid's shutdown time-out (Settings > Disk Settings).
WAIT_SECONDS=30

# Unraid's system log lives in memory and is lost at reboot, so each line is
# also kept on the flash drive. That is how you check, after a reboot, that
# the script ran.
KEEP_LOG="/boot/logs/rclone_unmount.log"

log() {
    local line
    line="$(date '+%d.%m.%Y %T') rclone_unmount: $*"
    echo "$line"
    logger -t rclone_unmount "$*"
    echo "$line" >>"$KEEP_LOG" 2>/dev/null
}

# The mount points are read from the mount script, so the two scripts cannot
# drift apart.
read_setting() {
    sed -n "s/^$1=\"\(.*\)\"/\1/p" "$MOUNT_SCRIPT" | head -n 1
}
# The rclone mount point is called MOUNT_POINT_REMOTE in newer copies of the
# mount script and MOUNT_POINT in older ones.
MOUNT_POINT=$(read_setting MOUNT_POINT_REMOTE)
[ -n "$MOUNT_POINT" ] || MOUNT_POINT=$(read_setting MOUNT_POINT)
MOUNT_POINT_MERGERFS=$(read_setting MOUNT_POINT_MERGERFS)
if [ -z "$MOUNT_POINT" ] || [ -z "$MOUNT_POINT_MERGERFS" ]; then
    log "could not read the mount points from $MOUNT_SCRIPT; nothing done"
    exit 1
fi

still_running() {
    pgrep -f "rclone.* mount .*${MOUNT_POINT}" >/dev/null ||
        pgrep -f "mergerfs .*${MOUNT_POINT_MERGERFS}" >/dev/null
}

stop_leftovers() { # stop_leftovers <signal>
    pkill "-$1" -f "mergerfs .*${MOUNT_POINT_MERGERFS}"
    pkill "-$1" -f "rclone.* mount .*${MOUNT_POINT}"
}

log "unmounting $MOUNT_POINT_MERGERFS and $MOUNT_POINT"
bash "$MOUNT_SCRIPT" stop

# The unmounts above are "lazy": they return at once. rclone keeps its cache
# and log files open on the array until it has really exited, and that alone
# is enough to keep /mnt/user busy.
waited=0
while still_running && [ "$waited" -lt "$WAIT_SECONDS" ]; do
    sleep 1
    waited=$((waited + 1))
done

if still_running; then
    log "still running after ${WAIT_SECONDS}s; asking rclone and mergerfs to stop"
    stop_leftovers TERM
    sleep 5
    if still_running; then
        log "still running; stopping them the hard way"
        stop_leftovers KILL
        sleep 1
    fi
fi

if still_running; then
    log "could not stop rclone or mergerfs; the array may not stop cleanly"
    exit 1
fi
log "mounts are down after ${waited}s"
