#! /usr/bin/env zsh

# Root check:
if [[ "root" != $(whoami) ]]; then
  print "You need root privileges to run this."
  exit 1
fi



###############################################################################
### Variables obtained via argv                                             ###
###############################################################################

# Rclone binary location:
RCLONE_BIN="rclone"

# Rclone remote name:
RCLONE_REMOTE="remote-crypted"

# Exclusion list location:
RSYNC_EXCLUDE_FROM="/opt/rclone-backup/exclusion_list"

# Flag for in-ram backup:
IN_RAM=1



# Allowed command line parameters:
FLAGS=(
  rclone         RCLONE_BIN          "rclone binary path"
  rclone-remote  RCLONE_REMOTE       "rclone remote to upload to"
  exclude-from   RSYNC_EXCLUDE_FROM  "rsync exclude-from list"
  in-ram         IN_RAM              "Perform the backup in a ram folder"
)

# Let's build the help function just once, as we may need it::
function help_reference()
{
  print "Usage: ${ZSH_ARGZERO:t} [options]\n"

  for FLAG VAR DESC in "${(@)FLAGS}"; do
    print "  ${(r:24:):---${FLAG}=VALUE} ${DESC} (default: ${(P)VAR})"
  done

  print "  ${(r:24:):--h, --help} Print this help reference"
}

# Now compose the SPEC variable to pass to zparseopts:
SPEC=(h -help)
for FLAG VAR DESC in "${(@)FLAGS}"; do
  SPEC+=( "-${FLAG}:" )
done

# And finally use it to read the parameters.
# If an invalid one is given print the help reference and quit.
typeset -A opts
zparseopts -D -E -F -A OPTS -- ${SPEC} || { help_reference >&2; exit 2 }

# If -h/--help has been given, print the help reference and quit:
(( ${+OPTS[-h]} || ${+OPTS[--help]} )) && { help_reference; exit 0 }

# Finally, set the variables' values from what we've been given:
for FLAG VAR DESC in "${(@)FLAGS}"; do
  (( ${+OPTS[--${FLAG}]} )) && typeset -g ${VAR}=${OPTS[--${FLAG}]#=}
done



###############################################################################
### Variables                                                               ###
###############################################################################

# Daily label:
DAILY_LABEL="$(date "+%u-%A")"

# Backup main folder:
BCK_FOLDER_BASE="/mnt/dietpi_userdata/00-BACKUPS"

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

# Services to stop:
SERVICES_TO_STOP=(
  "vaultwarden"
)

# Pi-hole's FTL binary:
FTL="pihole-FTL"

# Rclone remote to use with full path:
RCLONE_REMOTE="${RCLONE_REMOTE}:${DAILY_LABEL}"



###############################################################################
### Entry point                                                             ###
###############################################################################

# Log message:
print "Backup starting!"
print "Rclone bin: ${RCLONE_BIN}"
print "Rclone remote: ${RCLONE_REMOTE}"
print "Exclude list: ${RSYNC_EXCLUDE_FROM}"
print "In ram: ${IN_RAM}"
print "====="
[[ 1 == ${IN_RAM} ]] && print "Tmpfs size: ${TMPFS_SIZE}"
print "Daily path: ${BCK_FOLDER_DAILY}"
print "Backup paths: ${RSYNC_PATHS}"
print "Exclude list contents:"
print "====="
cat "${RSYNC_EXCLUDE_FROM}"
print "====="
print "Services to stop: ${SERVICES_TO_STOP}"
print ""

# So, first off, create the backup folder:
mkdir -p "${BCK_FOLDER_BASE}"

# If we have to perform an in-ram backup:
if [[ 1 == ${IN_RAM} ]]; then
  # Now mount it as tmpfs of the set size:
  mount -t tmpfs -o size="${TMPFS_SIZE}",mode=0755 tmpfs "${BCK_FOLDER_BASE}"

  # If this throws any kind of error, stop:
  if [[ 0 != $? ]]; then
    print "Failed to mount tmp folder, aborting!"
    exit 3
  fi
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
      --exclude="/${BCK_FOLDER_BASE#/mnt/}/" \
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

# Perform the rsync command again, so everything is clean:
print "Performing final copy with stopped services..."
rsync -aHAX \
      --info=progress2 \
      --delete \
      --ignore-errors \
      --exclude="/${BCK_FOLDER_BASE#/mnt/}/" \
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

# Once done, add in pihole's backup... If it's installed:
if [[ $(command -v "${FTL}") ]]; then
  cd "${BCK_FOLDER_DAILY}"
  print $PWD
  print "Removing older ${FTL}'s backups..."
  rm -f pi-hole_*.zip(N)
  print "Running ${FTL}'s teleporter..."
  "${FTL}" --teleporter
  cd - &> /dev/null
  print ""
fi

# If we have a path set for rclone, use it:
if [[ -n ${RCLONE_BIN} ]]; then
  print "Running rclone..."
  ${RCLONE_BIN} sync \
                "${BCK_FOLDER_DAILY}" \
                "${RCLONE_REMOTE}" \
                --progress \
                --transfers 4 \
                --links \
                --delete-after
  print ""
fi

# If we performed an in-ram backup:
if [[ 1 == ${IN_RAM} ]]; then
  # Finally, unmount the tmpfs folder to free up the data:
  print "Unmounting tmpfs..."
  CNT=0
  while mountpoint -q "${BCK_FOLDER_BASE}"; do
    CNT=$((CNT + 1))
    print " - Attempt 1"
    umount "${BCK_FOLDER_BASE}"
  done
  print " - Done!"
fi

