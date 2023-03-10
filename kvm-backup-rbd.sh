#!/bin/bash
# Copyright (c) 2022 Mr. Gecko's Media (James Coleman). http://mrgeckosmedia.com/

# This is for backing up Rados Block Device (Ceph) storage.

# A file to prevent overlapping runs.
PIDFILE="/tmp/backup-image.pid"

# If the pid file exists and process is running, exit.
if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if ps -p "$PID" >/dev/null; then
        echo "Backup process already running, exiting."
        exit 1
    fi
fi

# Create a new pid file for this process.
echo $BASHPID >"$PIDFILE"

# The pool in Ceph that you would like to backup.
POOL="libvirt"
# Pull images in pull from rbd driver.
IMAGES=$(rbd -p $POOL ls)
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

# Failures should remove pid file and exit with status code 1.
fail() {
    echo "$1"
    rm "$PIDFILE"
    exit 1
}

for IMAGE in $IMAGES; do
    # Export volume to borg backup.
    echo "Creating backup for $IMAGE"
    rbd export $POOL/$IMAGE - | pv | borg create \
        --verbose \
        --stats \
        --show-rc \
        "::$IMAGE-{now}" -

    if [ $? -ne 0 ]; then
        fail "Failed to backup $IMAGE"
    fi

    # Prune if options are configured.
    if [ -n "$PRUNE_OPTIONS" ]; then
        echo "Pruning backups for $IMAGE"
        borg prune --list \
            --show-rc \
            --glob-archives "$IMAGE-*" \
            $PRUNE_OPTIONS

        if [ $? -ne 0 ]; then
            fail "Failed to prune $DOMAIN"
        fi
    fi
done

# I save the status in a temporary file so I can error out and exit if a failure occurs.
DOMLIST_STATUS_TMP="/tmp/backup-rbd-domlist-tmp"
while read -r line; do
    # Extract the domain name from the line.
    DOMAIN=$(echo $line | awk '{print $2}')

    # Backup the domain info.
    echo "Backing up $DOMAIN xml"
    virsh dumpxml "$DOMAIN" | borg create \
        --verbose \
        --stats \
        --show-rc \
        "::$DOMAIN-xml-{now}" -

    if [ $? -ne 0 ]; then
        fail "Failed to backup $DOMAIN"
    fi

    # Prune if options are configured.
    if [ -n "$PRUNE_OPTIONS" ]; then
        echo "Pruning backups for $IMAGE"
        borg prune --list \
            --show-rc \
            --glob-archives "$DOMAIN-xml-*" \
            $PRUNE_OPTIONS

        if [ $? -ne 0 ]; then
            fail "Failed to prune $DOMAIN"
        fi
    fi
done < <(
    virsh list --all | tail -n +3
    echo $? >$DOMLIST_STATUS_TMP
)

# Get status from the domain listing.
status=1
if [ -f $DOMLIST_STATUS_TMP ]; then
    status=$(cat $DOMLIST_STATUS_TMP)
    rm $DOMLIST_STATUS_TMP
fi

# If status has an error, exit.
if [ $status -ne 0 ]; then
    fail "Domain listing failed"
fi

# Shrink repo.
borg compact

rm "$PIDFILE"
