#!/bin/bash
#
# THIS SCRIPT IS PROVIDED AS IS. You assume all responsibility if things go wrong. Have a backup,
# assume the worst will happen, and consider it a happy accident if this script works.
#
# Based off of docker-volumes.sh by Ricardo Branco https://github.com/ricardobranco777/docker-volumes.sh
#
# Migrates a docker container from one host to another, including volume data and any options set on
# the container. The original container will be brought down as part of this process, but will be
# started back up after the required snapshots have been taken. It is recommended that you validate
# the new container before destroying the old one.
#
# This is primarily intended to be used for a isolated container that has been manually created, or
# that has data on it that can't be migrated in another way. If you have a complicated setup, or
# have a way to recreated the container and its data without migrating it, this script if probably
# not for you.
#
# IF YOUR CONTAINER HAS VOLUMES: Volumes are assumed to be external, you will have to create them on
# the new host before running this script.
#
# Example usege: ./docker-migrate.sh uptime-kuma root 10.0.0.0
# This example mill migrate the uptime-kuma container to host 10.0.0.0 using user root. It is
# recommended that you set up an SSH keypair, otherwise you will have to enter the password
# multiple times
#
# NOTES:
#  + We use the Ubuntu 18.04 Docker image with tar v1.29 that uses SEEK_DATA/SEEK_HOLE to manage sparse files.
#

if [[ $1 == "-v" || $1 == "--verbose" ]] ; then
    v="-v"
    shift
fi

if [[ $# -ne 3 ]] ; then
    echo "Usage: $0 [-v|--verbose] CONTAINER USER HOST" >&2
    exit 1
fi

IMAGE="${IMAGE:-ubuntu:24.04}"

# Set DOCKER=podman if you want to use podman.io instead of docker
DOCKER=${DOCKER:-"docker"}

migrate_container() {
    echo "Local temp dir: $LOCAL_TMP"
    echo "Remote temp dir: $REMOTE_TMP"

    # Stop the container
    echo "Stopping container $CONTAINER"
    $DOCKER stop $CONTAINER

    # Create a new image
    $DOCKER inspect "$CONTAINER" > "$LOCAL_TMP/$CONTAINER.info"
    IMAGE_NAME=$($DOCKER run --rm -i stedolan/jq < "$LOCAL_TMP/$CONTAINER.info" -r '.[0].Config.Image')

    echo "Creating image $IMAGE_NAME for container $CONTAINER"
    echo "$DOCKER commit $CONTAINER $IMAGE_NAME"
    $DOCKER commit $CONTAINER $IMAGE_NAME

    # Save and load image to another host
    echo "Saving image and loading it onto remote host, this may take a while, be patient"
    $DOCKER save $IMAGE_NAME | ssh $USER@$HOST $DOCKER load

    echo "Saving volumes"
    save_volumes

    echo "Saving container options"
    save_container_options

    # start container on local host
    # echo "Restarting local container"
    # $DOCKER start "$CONTAINER"

    read -p "Ready to start creating? Press enter."

    # Copy volumes & compose to new host
    echo "Copying volumes and compose to remote host"
    scp $TAR_FILE_SRC $USER@$HOST:$TAR_FILE_DST
    scp $COMPOSE_FILE_SRC $USER@$HOST:$COMPOSE_FILE_DST

    # Create empty volumes
    volumes=$(get_volume_names)
    # if [ -n "$volumes" ]; then
    #     echo "$volumes" | xargs -0 -I{} ssh $USER@$HOST $DOCKER volume create --name {}
    # fi
    if [ -n "$volumes" ]; then
        for volume in $volumes; do
            echo "Creating volume: $volume"  # Debug
            ssh $USER@$HOST $DOCKER volume create --name $volume
        done
    fi

    # Create networks
    networks=$(get_networks)
    if [ -n "$networks" ]; then
        for network in $networks; do
            echo "Processing network: $network"  # Debug
            ssh $USER@$HOST $DOCKER network inspect $network >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo "Creating network: $network"  # Debug
                ssh $USER@$HOST $DOCKER network create $network
            else
                echo "Network already exists: $network"  # Debug
            fi
        done
    fi

    # Create container with the same options used in the previous container
    echo "Creating container on remote host"
    ssh $USER@$HOST "$DOCKER compose -f $COMPOSE_FILE_DST create"

    # Load the volumes
    echo "Loading volumes on remote host"
    load_volumes

    # Start container on remote host
    echo "Staring remote container"
    ssh $USER@$HOST "$DOCKER start $CONTAINER"

    echo "$0 completed successfully"
}

save_container_options () {
    $DOCKER run --rm -v /var/run/docker.sock:/var/run/docker.sock ghcr.io/red5d/docker-autocompose "$CONTAINER" > "$COMPOSE_FILE_SRC"
}

get_volumes () {
    cat <($DOCKER inspect --type container -f '{{range .Mounts}}{{printf "%v\x00" .Destination}}{{end}}' "$CONTAINER" | head -c -1) | sort -uz
}

# get_volume_names () {
#     cat <($DOCKER inspect --type container -f '{{range .Mounts}}{{printf "%v\x00" .Name}}{{end}}' "$CONTAINER" | head -c -1) | sort -uz
# }

get_volume_names () {
    docker inspect --type container -f '{{range .Mounts}}{{printf "%s " .Name}}{{end}}' "$CONTAINER"
}

get_networks () {
    cat <($DOCKER inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{if ne $k "host"}}{{$k}} {{end}}{{end}}' "$CONTAINER" | head -c -1) | sort -uz
}

# Clean up tar file creation
# save_volumes () {
#     chmod 777 $LOCAL_TMP
    
#     if [ -f "$TAR_FILE_SRC" ] ; then
#         echo "ERROR: $TAR_FILE_SRC already exists" >&2
#         exit 1
#     fi
#     umask 077
#     # Remove touch and handle tarball directly
#     #get_volumes | $DOCKER run --rm -i -v $LOCAL_TMP:/volumes --volumes-from "$CONTAINER" -e LC_ALL=C.UTF-8 $IMAGE tar -c --null -T- -f "/volumes/volumes.tar"
#     ##get_volumes | $DOCKER run --rm -i --volumes-from "$CONTAINER" -v "$LOCAL_TMP:/volumes" -e LC_ALL=C.UTF-8 $IMAGE tar -c --null -T- -f "/volumes/volumes.tar"

#     $DOCKER run --rm -i -v "$(pwd)/$LOCAL_TMP:/volumes" --volumes-from "$CONTAINER" $IMAGE touch "/volumes/testfile"
#     $DOCKER run --rm -i -v "$(pwd)/$LOCAL_TMP:/volumes" $IMAGE ls -l "/volumes/"
#     ls -l "$(pwd)/$LOCAL_TMP"


#     # $DOCKER run --rm -i --volumes-from "$CONTAINER" -v "$LOCAL_TMP:/volumes" -e LC_ALL=C.UTF-8 $IMAGE touch "/volumes/volumes.txt"
#     # echo "Mount it again in a new container and list files in volumes"
#     # $DOCKER run --rm -i -v "$LOCAL_TMP:/volumes" $IMAGE ls -l "/volumes/"
#     # echo "List local volumes"
#     # ls -l "$LOCAL_TMP"
#     # # Check tarball integrity
#     # tar -tvf "$LOCAL_TMP/volumes.tar"
#     # # Compress tarball
#     # gzip "$LOCAL_TMP/volumes.tar"
#     # # Verify final file
#     # ls -l "$LOCAL_TMP/volumes.tar.gz"
# }

# save_volumes () {
#     if [ -f "$TAR_FILE_SRC" ] ; then
#         echo "ERROR: $TAR_FILE_SRC already exists" >&2
#         exit 1
#     fi
#     umask 077
#     # Create a void tar file to avoid mounting its directory as a volume
#     #touch -- "$TAR_FILE_SRC"
#     tmp_dir=$(mktemp -du -p /)

#     # # debug
#     # get_volumes | $DOCKER run --rm -i --volumes-from "$CONTAINER" -v "$TAR_FILE_SRC:${tmp_dir}" $IMAGE sh -c "tar -cv --null -T- -f \"${tmp_dir}/$CONTAINER-volumes.tar\" && gzip \"${tmp_dir}/$CONTAINER-volumes.tar\""

#     # $DOCKER run --rm -i --volumes-from "$CONTAINER" -v "$TAR_FILE_SRC:${tmp_dir}" $IMAGE ls -l "${tmp_dir}/"
#     # tar -tvf "$TAR_FILE_SRC"
#     # df -h
#     # ls -l "$TAR_FILE_SRC"

#     get_volumes | xargs -0 echo
#     get_volumes | $DOCKER run --rm -i --volumes-from "$CONTAINER" -e LC_ALL=C.UTF-8 -v "$LOCAL_TMP:${tmp_dir}" $IMAGE tar -cv -a $v --null -T- -f "${tmp_dir}/volumes.tar"
#     tar -tvf "$LOCAL_TMP/volumes.tar"

# 	#get_volumes | $DOCKER run --rm -i --volumes-from "$CONTAINER" -e LC_ALL=C.UTF-8 -v "$TAR_FILE_SRC:${tmp_dir}" "$IMAGE" tar -c -a $v --null -T- -f "${tmp_dir}/${TAR_FILE_SRC##*/}"
# }

save_volumes () {
    if [ -f "$TAR_FILE_SRC" ] ; then
        echo "ERROR: $TAR_FILE_SRC already exists" >&2
        exit 1
    fi
    umask 077
    # Create a void tar file to avoid mounting its directory as a volume
    echo $TAR_FILE_SRC
    touch -- "$TAR_FILE_SRC"
    tmp_dir=$(mktemp -du -p /)
    get_volumes | $DOCKER run --rm -i --volumes-from "$CONTAINER" -e LC_ALL=C.UTF-8 -v "$TAR_FILE_SRC:/${tmp_dir}/${TAR_FILE_SRC##*/}" $IMAGE tar -c -a $v --null -T- -f "/${tmp_dir}/${TAR_FILE_SRC##*/}"
}

load_volumes () {
    tmp_dir=$(mktemp -du -p /)
    ssh $USER@$HOST "$DOCKER run --rm --volumes-from $CONTAINER -e LC_ALL=C.UTF-8 -v \"$TAR_FILE_DST:${tmp_dir}/${TAR_FILE_DST##*/}\":ro "$IMAGE" tar -xp $v -S -f \"${tmp_dir}/${TAR_FILE_DST##*/}\" -C / --overwrite"
}

CONTAINER="$1"
USER="$2"
HOST="$3"

LOCAL_TMP=$(pwd)/migrate-temp #$(mktemp -d)
REMOTE_TMP=$(ssh $USER@$HOST "mktemp -d")

TAR_FILE_NAME="$CONTAINER-volumes.tar.gz"
TAR_FILE_SRC="$LOCAL_TMP/$TAR_FILE_NAME" #$(readlink -f $LOCAL_TMP/$TAR_FILE_NAME)
echo "LOCAL_TMP: $LOCAL_TMP"
echo "TAR_FILE_NAME: $TAR_FILE_NAME"
echo "TAR_FILE_SRC: $TAR_FILE_SRC"
TAR_FILE_DST="$REMOTE_TMP/$TAR_FILE_NAME"

COMPOSE_FILE_NAME="$CONTAINER.compose.yml"
COMPOSE_FILE_SRC="$LOCAL_TMP/$COMPOSE_FILE_NAME"
COMPOSE_FILE_DST="$REMOTE_TMP/$COMPOSE_FILE_NAME"

set -e
migrate_container
