#!/bin/bash
# This script get active torrent list from transmission and tells rclone to cache files

# lock
if [[ -f /var/lock/cache_torrents ]]; then
        echo "Script already running"
        exit 1
else
        touch /var/lock/cache_torrents
fi


# settings
        #Transmission
        RPC_USER="redacted"
        RPC_PASSWORD="redacted"
        RPC_HOST="192.168.1.28:9091"
        #RClone remote
        RC_USER="redacted"
        RC_PASS="redacted"
        RC_REMOTE_LOCAL_PATH="/mnt/user0/data/"
        RC_REMOTE="data-cache:"
        RC_CACHE_DB_PATH="/mnt/cache/rclone/cache-backend/data-cache/"

# test rclone mount
        if ! mount | grep $RC_REMOTE > /dev/null;
        then
                echo "Error: Rclone cache not mounted"
                rm /var/lock/cache_torrents
                exit 1
        fi

# get header for this Transmission RPC session
        RPC_LOGIN=" --user ${RPC_USER}:${RPC_PASSWORD}"
        SESSION_HEADER=$(curl --max-time 5 --silent --anyauth${RPC_LOGIN} ${RPC_HOST}/transmission/rpc/ | sed 's/.*<code>//g;s/<\/code>.*//g')
        if [[ -z $SESSION_HEADER ]];
        then
                echo "Error: Cannot connect to transmission"
                rm /var/lock/cache_torrents
                exit 1
        fi

# get full torrent list
        TORRENT_LIST=$(curl --silent --anyauth${RPC_LOGIN} --header "${SESSION_HEADER}" "http://${RPC_HOST}/transmission/rpc" \
           -d "{\"method\":\"torrent-get\",\"arguments\": {\"ids\":\"recently-active\",\"fields\":[\"id\",\"activityDate\",\"name\",\"downloadDir\",\"files\"]}}" \
           | jq '.arguments.torrents|=sort_by(-.activityDate)')
        NB_TORRENTS=$(echo ${TORRENT_LIST} | jq '.arguments.torrents | length')

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
                        # get file
                        TORRENT_FILE=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].files['$(($j - 1))'].name' | sed 's|\"||g')
                        FILE_TO_CACHE=$(echo ${TORRENT_PATH}/${TORRENT_FILE} | sed 's|\"\"|\/|g' | sed 's|\"||g' | sed 's|data\/||g')
                        echo -e "\tFile $j/$NB_FILES ${TORRENT_FILE}:"
        # cache it!
                        REMOTE_SIZE=$(du -s "${RC_REMOTE_LOCAL_PATH}${FILE_TO_CACHE}" | awk '{print $1}')
                        CACHE_DB_SIZE=$(du -s "${RC_CACHE_DB_PATH}${FILE_TO_CACHE}" | awk '{print $1}')
                        if [[ $REMOTE_SIZE -eq $CACHE_DB_SIZE ]]
                        then
                                echo -e "\t\t-> File already fully cached, nothing to do"
                        else
                                echo -e "\t\t=> File not fully cached, caching full file"
                                rclone rc --rc-user=$RC_USER --rc-pass=$RC_PASS cache/fetch chunks=: file="${FILE_TO_CACHE}"
        echo ""
                        fi
                done
        echo ""
        done

rm /var/lock/cache_torrents
exit 0
