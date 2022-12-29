#!/bin/bash
# Copyright (c) 2022 Mr. Gecko's Media (James Coleman). http://mrgeckosmedia.com/

# This is for backing up block devices in virsh
# which use image files such as qcow2.
# This also works with GlusterFS so long as your
# volume is mounted.

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

# Allows providing an argument of a domain to specifically backup.
BACKUP_DOMAIN="$1"

# I save the status in a temporary file so I can error out and exit if a failure occurs.
DOMLIST_STATUS_TMP="/tmp/backup-image-domlist-tmp"
while read -r line; do
    # Extract the domain name and status from the line.
    DOMAIN=$(echo $line | awk '{print $2}')
    DOMSTATUS=$(echo $line | awk '{for (i=3; i<NF; i++) printf $i " "; if (NF>=3) print $NF}')

    # If the domain is empty, its not needed.
    if [ -z "$DOMAIN" ]; then
        continue
    fi

    # If a backup domain was provided, we're only going to backup that domain.
    if [ -n "$BACKUP_DOMAIN" ] && [[ "$BACKUP_DOMAIN" != "$DOMAIN" ]]; then
        continue
    fi

    # Get the images that need backing up.
    DEVS=()
    IMAGES=()
    BLKLIST_STATUS_TMP="/tmp/backup-image-blklist-tmp"
    while read -r line; do
        # Extract the device and image from the line.
        DEV=$(echo $line | awk '{print $1}')
        IMAGE=$(echo $line | awk '{for (i=2; i<NF; i++) printf $i " "; if (NF>=2) print $NF}')

        # Ignore empty line or no image.
        if [ -z "$IMAGE" ] || [[ "$IMAGE" == "-" ]]; then
            continue
        fi

        # Ignore iso files.
        if [[ "$IMAGE" =~ \.iso$ ]]; then
            continue
        fi

        # This image needs backing up.
        DEVS+=("$DEV")
        IMAGES+=("$IMAGE")
    done < <(
        virsh domblklist $DOMAIN | tail -n +3
        echo $? >$BLKLIST_STATUS_TMP
    )

    # Get status from the block listing.
    status=1
    if [ -f $BLKLIST_STATUS_TMP ]; then
        status=$(cat $BLKLIST_STATUS_TMP)
        rm $BLKLIST_STATUS_TMP
    fi

    # If status has an error, exit.
    if [ $status -ne 0 ]; then
        echo "Domain block listing failed"
        exit 1
    fi

    # For each image we can backup, back it up.
    for ((i = 0; i < ${#DEVS[@]}; i++)); do
        DEV=${DEVS[$i]}
        IMAGE=${IMAGES[$i]}

        # If the domain is running, we need to snapshot the disk so we can backup cleanly.
        if [[ "$DOMSTATUS" == "running" ]]; then
            echo "Creating snapshot for $DOMAIN ($DEV)"
            virsh snapshot-create-as --domain "$DOMAIN" \
                --name backup \
                --no-metadata \
                --atomic \
                --disk-only \
                --diskspec $DEV,snapshot=external

            if [ $? -ne 0 ]; then
                echo "Failed to create snapshot for $DOMAIN ($DEV)"
                exit 1
            fi
        fi

        # Backup the image.
        echo "Creating backup for $DOMAIN ($DEV)"
        IMAGENAME=$(basename "$IMAGE")
        cat "$IMAGE" | pv | borg create \
            --verbose \
            --stats \
            --show-rc \
            --stdin-name "$IMAGENAME" \
            "::$DOMAIN-$DEV-{now}" -

        if [ $? -ne 0 ]; then
            echo "Failed to backup $DOMAIN ($DEV)"
            exit 1
        fi

        # Prune if options are configured.
        if [ -n "$PRUNE_OPTIONS" ]; then
            echo "Pruning backups for $DOMAIN ($DEV)"
            borg prune --list \
                --show-rc \
                --glob-archives "$DOMAIN-$DEV-*" \
                $PRUNE_OPTIONS

            if [ $? -ne 0 ]; then
                echo "Failed to prune $DOMAIN ($DEV)"
                exit 1
            fi
        fi

        # If the domain is running, commit the changes saved to the snapshot to the image to finish the backup.
        if [[ "$DOMSTATUS" == "running" ]]; then
            echo "Commit changes for $DOMAIN ($DEV)"
            virsh blockcommit \
                "$DOMAIN" \
                "$DEV" \
                --active \
                --verbose \
                --pivot \
                --delete

            if [ $? -ne 0 ]; then
                echo "Could not commit changes $DOMAIN ($DEV). This may be a major issue and VM may be broken now."
                exit 1
            fi
        fi
    done

    # Backup the domain info.
    echo "Backing up $DOMAIN xml"
    virsh dumpxml "$DOMAIN" | borg create \
        --verbose \
        --stats \
        --show-rc \
        "::$DOMAIN-xml-{now}" -

    if [ $? -ne 0 ]; then
        echo "Failed to backup $DOMAIN"
        exit 1
    fi

    # Prune if options are configured.
    if [ -n "$PRUNE_OPTIONS" ]; then
        echo "Pruning backups for $IMAGE"
        borg prune --list \
            --show-rc \
            --glob-archives "$DOMAIN-xml-*" \
            $PRUNE_OPTIONS

        if [ $? -ne 0 ]; then
            echo "Failed to prune $DOMAIN"
            exit 1
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
    echo "Domain listing failed"
    exit 1
fi

# Shrink repo.
borg compact
