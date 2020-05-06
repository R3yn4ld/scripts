#!/bin/bash
# This script gets active torrents list from Transmission, playing sessions from Plex,  and tells rsync to copy them to cache drive

# settings
        #Transmission
        RPC_USER="plex"
        RPC_PASSWORD="pl3xpl3x"
        RPC_HOST="192.168.1.28:9091"

        #Plex
        PLEX_TOKEN="eRVfis8yqFEbdT6bsd6M"
        PLEX_HOST="192.168.1.20:32400"

        #Rsync path
        STORAGE_PATH="/mnt/user0/data/"
        CACHE_PATH="/mnt/cache/data/"

##### No modification below this line #####

# lock
if [[ -f /var/lock/rsync-cache_plex_transmission ]]; then
        echo "Script already running"
        exit 1
else
        touch /var/lock/rsync-cache_plex_transmission
fi

##################
# Rsync Function #
##################
rsync_cache() {
# get files and path
        ORIG_FILE=$1
        DEST_FILE=$2
        ORIG_PATH=$3
        DEST_PATH=$4

# get dir
        ORIG_DIR=$(dirname "${ORIG_FILE}")
        DEST_DIR=$(dirname "${DEST_FILE}")

# check if destination exists and size
        ORIG_SIZE=$(du -s "${ORIG_FILE}" | awk '{print $1}')
        if [[ -f "${DEST_FILE}" ]];
        then
                DEST_SIZE=$(du -s "${DEST_FILE}" | awk '{print $1}')
        else
                DEST_SIZE=0
        fi

        if [[ $ORIG_SIZE -eq $DEST_SIZE ]]
        then
# if same file nothing to do
                echo -e "\t\t-> File already fully cached, nothing to do"
        else
# else sync file
                echo -e "\t\t=> File not fully cached, caching full file"
                mkdir -p "${DEST_DIR}"
                rsync -avhP "${ORIG_FILE}" "${DEST_FILE}"
        # get hardlinks from source
                find "${ORIG_PATH}" -samefile "${ORIG_FILE}" | while read ORIG_LINK
                do
                        if [[ ! "${ORIG_FILE}" = "${ORIG_LINK}" ]]
                        then
                                DEST_LINK=$(echo ${ORIG_LINK} | sed "s|`echo ${ORIG_PATH}`|`echo ${DEST_PATH}`|")
                                echo "Creating hardlink: ${DEST_LINK}"
                                # rm destination file if exist
                                [[ -f "${DEST_LINK}" ]] && rm "${DEST_LINK}"
                                DEST_LINK_DIR=$(dirname "${DEST_LINK}")
# and create hardlinks on destination
                                mkdir -p "${DEST_LINK_DIR}"
                                ln "${DEST_FILE}" "${DEST_LINK}"
                        fi
                done
        fi
}

################
# Transmission #
################

# get full torrent list
        # get header for this Transmission RPC session
        RPC_LOGIN=" --user ${RPC_USER}:${RPC_PASSWORD}"
        SESSION_HEADER=$(curl --max-time 5 --silent --anyauth${RPC_LOGIN} ${RPC_HOST}/transmission/rpc/ | sed 's/.*<code>//g;s/<\/code>.*//g')
        if [[ -z $SESSION_HEADER ]];
        then
                echo "Error: Cannot connect to transmission"
                rm /var/lock/rsync-cache_plex_transmission
                exit 1
        fi
        # get torrent list
        TORRENT_LIST=$(curl --silent --anyauth${RPC_LOGIN} --header "${SESSION_HEADER}" "http://${RPC_HOST}/transmission/rpc" \
           -d "{\"method\":\"torrent-get\",\"arguments\": {\"ids\":\"recently-active\",\"fields\":[\"id\",\"activityDate\",\"name\",\"downloadDir\",\"files\"]}}" \
           | jq '.arguments.torrents|=sort_by(-.activityDate)')
        NB_TORRENTS=$(echo ${TORRENT_LIST} | jq '.arguments.torrents | length')
        echo "------------------"
        echo "$NB_TORRENTS active torrents:"
        echo "------------------"
# for each torrent
        for i in `seq $NB_TORRENTS`
        do
        # get torrent path
                TORRENT_PATH=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].downloadDir' | sed 's|\/data|data|')
                TORRENT_NAME=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].name')
                NB_FILES=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].files | length')
                echo "$i/$NB_TORRENTS ${TORRENT_NAME} in ${TORRENT_PATH}"

        # for each file
                for j in `seq $NB_FILES`
                do
# get each file path
                        TORRENT_FILE=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].files['$(($j - 1))'].name' | sed 's|\"||g')
                        FILE_TO_CACHE=$(echo ${TORRENT_PATH}/${TORRENT_FILE} | sed 's|\"\"|\/|g' | sed 's|\"||g' | sed 's|data\/||g')
                        echo -e "\tFile $j/$NB_FILES ${TORRENT_FILE}:"
                        STORAGE_FILE="${STORAGE_PATH}${FILE_TO_CACHE}"
                        CACHE_FILE="${CACHE_PATH}${FILE_TO_CACHE}"
# and send to rsync
                        rsync_cache "${STORAGE_FILE}" "${CACHE_FILE}" "${STORAGE_PATH}" "${CACHE_PATH}"
                done
        echo ""
        done

########
# Plex #
########

# get Plex sessions
        STATUS_SESSIONS=$(curl --silent http://${PLEX_HOST}/status/sessions -H "X-Plex-Token: $PLEX_TOKEN")
        NB_SESSIONS=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/@size)' -)
        echo "-----------------------"
        echo "$NB_SESSIONS active plex sessions:"
        echo "-----------------------"

# for each session
        for i in `seq $NB_SESSIONS`
        do
                ID=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/Video['$i']/@ratingKey)' -)
# get file path
                PLEX_FILE=$(curl --silent http://${PLEX_HOST}/library/metadata/$ID | xmllint --xpath 'string(//MediaContainer/Video/Media/Part/@file)' -)
                FILE_TO_CACHE=$(echo ${PLEX_FILE} | sed 's|\"\"|\/|g' | sed 's|\"||g' | sed 's|\/data\/||')
                echo "$i/$NB_SESSIONS: $FILE_TO_CACHE"
                STORAGE_FILE="${STORAGE_PATH}${FILE_TO_CACHE}"
                CACHE_FILE="${CACHE_PATH}${FILE_TO_CACHE}"
# and send to rsync
                rsync_cache "${STORAGE_FILE}" "${CACHE_FILE}" "${STORAGE_PATH}" "${CACHE_PATH}"
        done

rm /var/lock/rsync-cache_plex_transmission
exit 0
