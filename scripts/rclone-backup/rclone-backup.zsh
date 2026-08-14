#! /usr/bin/env zsh

# Root check:
if [[ "root" != $(whoami) ]]; then
  print "You need root privileges to run this."
  exit 1
fi



###############################################################################
### Variables                                                               ###
###############################################################################

# Daily label:
DAILY_LABEL="$(date "+%u-%A")"

# Backup main folder:
BCK_FOLDER_BASE="/tmp/dietpi_ram_backup"

# Per-day named folder:
BCK_FOLDER_DAILY="${BCK_FOLDER_BASE}/${DAILY_LABEL}"

# Tmpfs size:
TMPFS_SIZE="3000M"

# Stuff to backup:
RSYNC_PATHS=(
  "/etc"
  "/home"
  "/mnt/dietpi_userdata"
  "/opt"
  "/root"
)

# Exclusion list:
RSYNC_EXCLUDE_FROM="/opt/rclone-backup/exclusion_list"

# Services to stop:
SERVICES_TO_STOP=(
  "nginx"
  "pihole-FTL"
  "vaultwarden"
)

# Rclone binary location:
RCLONE_BIN="rclone"

# Rclone remote to use:
RCLONE_REMOTE="remote-crypted:${DAILY_LABEL}"



###############################################################################
### Entry point                                                             ###
###############################################################################

# Log message:
print "Backup starting!"
print "Daily path: ${BCK_FOLDER_DAILY}"
print "Tmpfs size: ${TMPFS_SIZE}"
print "Backup paths: ${RSYNC_PATHS}"
print "Exclude list: ${RSYNC_EXCLUDE_FROM}"
print "Exclude list contents:"
print "==="
cat "${RSYNC_EXCLUDE_FROM}"
print "==="
print "Services to stop: ${SERVICES_TO_STOP}"
print "Rclone bin: ${RCLONE_BIN}"
print "Rclone remote: ${RCLONE_REMOTE}"
print ""

# So, first off, create the backup folder:
mkdir -p "${BCK_FOLDER_BASE}"

# Now mount it as tmpfs of the set size:
mount -t tmpfs -o size="${TMPFS_SIZE}",mode=0755 tmpfs "${BCK_FOLDER_BASE}"

# If this throws any kind of error, stop:
if [[ 0 != $? ]]; then;
  print "Failed to mount tmp folder, aborting!"
  exit 2
fi

# Now create the named subfolder:
mkdir -p "${BCK_FOLDER_DAILY}"

# Copy data via rsync, without stopping any service, so we have most of it
# ready:
print "Performing first copy..."
rsync -aHAX \
      --info=progress2 \
      --delete \
      --ignore-errors \
      --exclude-from="${RSYNC_EXCLUDE_FROM}" \
      ${RSYNC_PATHS} \
      "${BCK_FOLDER_DAILY}/"
print ""

# Now stop the services:
for s in ${SERVICES_TO_STOP}; do
  print "Stopping service: ${s}"
  systemctl stop "${s}"
done
print ""

# Sync, just to be sure:
print "Syncing..."
sync
print ""

# Perform the rsync command again, so everything is clean:
print "Performing final copy with stopped services..."
rsync -aHAX \
      --info=progress2 \
      --delete \
      --ignore-errors \
      --exclude-from="${RSYNC_EXCLUDE_FROM}" \
      ${RSYNC_PATHS} \
      "${BCK_FOLDER_DAILY}/"
print ""

# Then start up the services again:
for s in ${SERVICES_TO_STOP}; do
  print "Starting service: ${s}"
  systemctl start "${s}"
done
print ""

# Now back it all up via rclone:
print "Running rclone..."
${RCLONE_BIN} sync \
              "${BCK_FOLDER_DAILY}" \
              "${RCLONE_REMOTE}" \
              --progress \
              --transfers 4 \
              --links \
              --delete-after
print ""

# Finally, unmount the tmpfs folder to free up the data:
print "Syncing and unmounting tmpfs..."
sync
sync
umount "${BCK_FOLDER_BASE}"

