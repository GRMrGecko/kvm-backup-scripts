#!/bin/bash
# Copyright (c) 2022 Mr. Gecko's Media (James Coleman). http://mrgeckosmedia.com/

# This is for backing up Rados Block Device (Ceph) storage.

# A file to prevent overlapping runs.
PIDFILE="/tmp/backup-image.pid"

# If the pid file exists and process is running, exit.
if [[ -f "$PIDFILE" ]]; then
    PID=$(cat "$PIDFILE")
    if ps -p "$PID" >/dev/null; then
        echo "Backup process already running, exiting."
        exit 1
    fi
fi

# Create a new pid file for this process.
echo $BASHPID >"$PIDFILE"

# The borg repository we're backing up to.
export BORG_REPO='/media/Storage/Backup/kvm'
# If you have a passphrase for your repository,
# set it here or you can use bash to retrieve it.
# export BORG_PASSPHRASE=''
# Set answers for automation.
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_CHECK_I_KNOW_WHAT_I_AM_DOING=NO
export BORG_DELETE_I_KNOW_WHAT_I_AM_DOING=NO
# Set to empty string to disable pruning.
PRUNE_OPTIONS="--keep-daily 7 --keep-weekly 4 --keep-monthly 6"

# Remove PID file on exit.
cleanup() {
    rm "$PIDFILE"
}
trap cleanup EXIT

# Name the snapshot today's date.
SNAPSHOT_NAME=$(date '+%Y-%m-%dT%H-%M-%S')

# Keep number of snapshots in RBD.
SNAPSHOTS_KEEP=0

# Allows providing an argument of a domain to specifically backup.
BACKUP_DOMAIN="$1"

# Failures should remove pid file and exit with status code 1.
fail() {
    echo "$1"
    exit 1
}

# If the domain is running, commit the changes saved to the snapshot to the image to finish the backup.
cleanupSnapshots() {
    IMAGE="$1"
    snapshots=()
    
    # Read list of snapshots for the provided image.
    SNAPLIST_STATUS_TMP="/tmp/backup-snap-tmp"
    while read -r _ NAME _; do
        snapshots+=("$NAME")
    done < <(
        rbd snap list "$IMAGE" | tail -n +2
        echo "${PIPESTATUS[0]}" >"$SNAPLIST_STATUS_TMP"
    )

    # Get status from the snapshot listing.
    status=1
    if [[ -f $SNAPLIST_STATUS_TMP ]]; then
        status=$(cat "$SNAPLIST_STATUS_TMP")
        rm "$SNAPLIST_STATUS_TMP"
    fi

    # If status has an error, exit.
    if ((status!=0)); then
        fail "Snapshot listing failed"
    fi

    # If the snapshot count is more than the number to keep,
    # remove snapshots until count matches.
    # The snapshots are listed from oldest to newest, so this
    # should keep the newer snapshots.
    snpashot_count=${#snapshots[@]}
    if ((snpashot_count>=SNAPSHOTS_KEEP)); then
        # Loop through snapshots until we removed enough to equal keep count.
        for ((i = 0; snpashot_count-i > SNAPSHOTS_KEEP; i++)); do
            NAME=${snapshots[$i]}
            echo "Removing snapshot: $IMAGE@$NAME"
            # Remove snapshot.
            rbd snap remove "$IMAGE@$NAME"
        done
    fi
}

# I save the status in a temporary file so I can error out and exit if a failure occurs.
DOMLIST_STATUS_TMP="/tmp/backup-image-domlist-tmp"
while read -r _ DOMAIN _; do
    # If the domain is empty, its not needed.
    if [[ -z "$DOMAIN" ]]; then
        continue
    fi

    # If a backup domain was provided, we're only going to backup that domain.
    if [[ -n "$BACKUP_DOMAIN" ]] && [[ "$BACKUP_DOMAIN" != "$DOMAIN" ]]; then
        continue
    fi

    # Get the images that need backing up.
    DEVS=()
    IMAGES=()
    BLKLIST_STATUS_TMP="/tmp/backup-image-blklist-tmp"
    while read -r DEV IMAGE; do
        # Ignore empty line or no image.
        if [[ -z "$IMAGE" ]] || [[ "$IMAGE" == "-" ]]; then
            continue
        fi

        # Ignore iso files.
        if [[ "$IMAGE" =~ \.iso$ ]]; then
            continue
        fi

        # Ignore non-rbd files.
        if [[ "$IMAGE" =~ ^\/ ]]; then
            continue
        fi

        # This image needs backing up.
        DEVS+=("$DEV")
        IMAGES+=("$IMAGE")
    done < <(
        virsh domblklist "$DOMAIN" | tail -n +3
        echo "${PIPESTATUS[0]}" >"$BLKLIST_STATUS_TMP"
    )

    # Get status from the block listing.
    status=1
    if [[ -f $BLKLIST_STATUS_TMP ]]; then
        status=$(cat "$BLKLIST_STATUS_TMP")
        rm "$BLKLIST_STATUS_TMP"
    fi

    # If status has an error, exit.
    if ((status!=0)); then
        fail "Domain block listing failed"
    fi

    # For each image we can backup, back it up.
    for ((i = 0; i < ${#DEVS[@]}; i++)); do
        DEV=${DEVS[$i]}
        IMAGE=${IMAGES[$i]}
        RBD_POOL=${IMAGE%/*}
        RBD_IMAGE=${IMAGE##*/}
        BACKUP_NAME="${RBD_POOL}_${RBD_IMAGE}"

        # Create a snapshot.
        rbd snap create "$IMAGE@$SNAPSHOT_NAME"

        # Export volume to borg backup.
        echo "Creating backup for $IMAGE"
        if ! rbd export "$IMAGE@$SNAPSHOT_NAME" - | pv | borg create \
                --verbose \
                --stats \
                --show-rc \
                "::$BACKUP_NAME-{now}" -; then
            fail "Failed to backup $IMAGE"
        fi

        # Prune if options are configured.
        if [[ -n "$PRUNE_OPTIONS" ]]; then
            echo "Pruning backups for $IMAGE"
            if ! eval borg prune --list \
                    --show-rc \
                    --glob-archives "'$BACKUP_NAME-*'" \
                    "$PRUNE_OPTIONS"; then
                fail "Failed to prune $DOMAIN"
            fi
        fi

       # Cleanup snapshots.
       cleanupSnapshots "$IMAGE"
    done

    # Backup the domain info.
    echo "Backing up $DOMAIN xml"
    if ! virsh dumpxml "$DOMAIN" | borg create \
            --verbose \
            --stats \
            --show-rc \
            "::$DOMAIN-xml-{now}" -; then
        fail "Failed to backup $DOMAIN"
    fi

    # Prune if options are configured.
    if [[ -n "$PRUNE_OPTIONS" ]]; then
        echo "Pruning backups for $IMAGE"
        if ! eval borg prune --list \
                --show-rc \
                --glob-archives "'$DOMAIN-xml-*'" \
                "$PRUNE_OPTIONS"; then
            fail "Failed to prune $DOMAIN"
        fi
    fi
done < <(
    virsh list --all | tail -n +3
    echo "${PIPESTATUS[0]}" >"$DOMLIST_STATUS_TMP"
)

# Get status from the domain listing.
status=1
if [[ -f $DOMLIST_STATUS_TMP ]]; then
    status=$(cat "$DOMLIST_STATUS_TMP")
    rm "$DOMLIST_STATUS_TMP"
fi

# If status has an error, exit.
if ((status!=0)); then
    fail "Domain listing failed"
fi

# Shrink repo.
borg compact
