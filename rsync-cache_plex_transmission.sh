#!/bin/bash
# This script gets actives torrents list from Transmission, playing sessions from Plex,  and tells rsync to copy them to cache drive

# settings
{
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
        CACHE_DISK="/dev/mapper/nvme0n1p1"
        CACHE_MIN_FREE_SPACE_PCT="90"
		
		#Options (set to true or false)
		TRANSMISSION_ENABLED=true
		PLEX_ENABLED=true
		PLEX_CACHE_NEXT_EPISODE=true
		PLEX_CACHE_SEASON_TILL_END=false
		VERBOSE=false # Under construction
}
##### No modification below this line #####

sys_checks() {
# lock
		if [[ -f /var/lock/rsync-cache_plex_transmission ]]; then
				echo "Script already running"
				exit 1
		else
				touch /var/lock/rsync-cache_plex_transmission
		fi

# check that path are mounted
		if [[ ! -d $STORAGE_PATH ]] || [[ ! -d $CACHE_PATH ]];
		then
				echo "Paths are not accessibles"
				rm /var/lock/rsync-cache_plex_transmission
				exit 1
		fi
}

#######################
# Transfers functions #
#######################
rsync_transfer() {
# get files and path
        ORIG_FILE=$1
        DEST_FILE=$2
        ORIG_PATH=$3
        DEST_PATH=$4
		RS_OPTIONS=$5

# check if original file exist
		if [[ ! -f "${ORIG_FILE}" ]] && [[ -f "${DEST_FILE}" ]]
		then
			echo "File is on cache only"
			return
		fi
		if [[ -f "${DEST_FILE}" ]]
		then
			return
		fi

# get dir
        ORIG_DIR=$(dirname "${ORIG_FILE}")
        DEST_DIR=$(dirname "${DEST_FILE}")

# sync file
		mkdir -p "${DEST_DIR}"
		rsync -avhq --info=progress2 "${ORIG_FILE}" "${DEST_FILE}"
		RSYNC_RESULT=$?

# sync hardlinks
		hardlink_transfer "${ORIG_FILE}" "${DEST_FILE}" "${ORIG_PATH}" "${DEST_PATH}" "${RS_OPTIONS}"

# remove original file if requested
		if [[ "${RS_OPTIONS}" = "--remove-source-files" ]]
		then
			echo "Delete ${ORIG_FILE}"
			rm "${ORIG_FILE}"
		fi
}
hardlink_transfer() {
# get files and path
        ORIG_FILE=$1
        DEST_FILE=$2
        ORIG_PATH=$3
        DEST_PATH=$4
		RS_OPTIONS=$5

# get hardlinks from source
		find "${ORIG_PATH}" -samefile "${ORIG_FILE}" | while read ORIG_LINK
		do
				if [[ ! "${ORIG_FILE}" = "${ORIG_LINK}" ]];
				then
						DEST_LINK=$(echo ${ORIG_LINK} | sed "s|`echo ${ORIG_PATH}`|`echo ${DEST_PATH}`|")
						# if DEST is not a hardlink
						if [[ -f "${DEST_LINK}" ]] && [[ ! `stat -c %h "${DEST_LINK}"` -gt 1 ]]
						then
							$VERBOSE && echo "Creating hardlink: ${DEST_LINK}"
							# rm destination file if exist
							[[ -f "${DEST_LINK}" ]] && rm "${DEST_LINK}"
							DEST_LINK_DIR=$(dirname "${DEST_LINK}")
# and create hardlinks on destination
							mkdir -p "${DEST_LINK_DIR}"
							ln "${DEST_FILE}" "${DEST_LINK}"
							if [[ ! $? -eq 0 ]] 
							then
								echo "Error: cannot hardlink ${DEST_FILE}"
								echo "to ${DEST_LINK}"
								return 1
							fi
						else
							$VERBOSE && echo "Hardlink exists"
						fi
# remove hardlinks from source
						if [[ "${RS_OPTIONS}" = "--remove-source-files" ]]
						then
							$VERBOSE && echo "Delete hardlink ${ORIG_LINK}"
							rm "${ORIG_LINK}"
						fi

				fi
		done
}

################
# Transmission #
################
transmission_cache() {
# get full torrent list
        # get header for this Transmission RPC session
        RPC_LOGIN=" --user ${RPC_USER}:${RPC_PASSWORD}"
        SESSION_HEADER=$(curl --max-time 5 --silent --anyauth${RPC_LOGIN} ${RPC_HOST}/transmission/rpc/ | sed 's/.*<code>//g;s/<\/code>.*//g')
        if [[ -z $SESSION_HEADER ]];
        then
                echo "Error: Cannot connect to transmission"
                rm /var/lock/rsync-cache_plex_transmission
                return 1
        fi
        # get torrent list
        TORRENT_LIST=$(curl --silent --anyauth${RPC_LOGIN} --header "${SESSION_HEADER}" "http://${RPC_HOST}/transmission/rpc" \
           -d "{\"method\":\"torrent-get\",\"arguments\": {\"ids\":\"recently-active\",\"fields\":[\"id\",\"activityDate\",\"name\",\"downloadDir\",\"files\"]}}" \
           | jq '.arguments.torrents|=sort_by(-.activityDate)')
        NB_TORRENTS=$(echo ${TORRENT_LIST} | jq '.arguments.torrents | length')
        echo "-----------------------"
        echo "$NB_TORRENTS active(s) torrent(s):"
        echo "-----------------------"
# for each torrent
        for i in `seq $NB_TORRENTS`
        do
        # get torrent path
                TORRENT_PATH=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].downloadDir' | sed 's|\/data|data|')
                TORRENT_NAME=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].name')
                NB_FILES=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].files | length')
                echo "$i/$NB_TORRENTS: ${TORRENT_NAME}:"

        # for each file
                for j in `seq $NB_FILES`
                do
# get each file path
                        TORRENT_FILE=$(echo ${TORRENT_LIST} | jq '.arguments.torrents['$(($i - 1))'].files['$(($j - 1))'].name' | sed 's|\"||g')
                        FILE_TO_CACHE=$(echo ${TORRENT_PATH}/${TORRENT_FILE} | sed 's|\"\"|\/|g' | sed 's|\"||g' | sed 's|data\/||g')
                        echo "Caching file $j/$NB_FILES: ${TORRENT_FILE}"
                        STORAGE_FILE="${STORAGE_PATH}${FILE_TO_CACHE}"
                        CACHE_FILE="${CACHE_PATH}${FILE_TO_CACHE}"
# and send to rsync
						RS_OPTIONS=""
                        rsync_transfer "${STORAGE_FILE}" "${CACHE_FILE}" "${STORAGE_PATH}" "${CACHE_PATH}" "${RS_OPTIONS}"
                done
        echo ""
        done
}

########
# Plex #
########
plex_cache() {
# get Plex sessions
        STATUS_SESSIONS=$(curl --silent http://${PLEX_HOST}/status/sessions -H "X-Plex-Token: $PLEX_TOKEN")
        if [[ -z $STATUS_SESSIONS ]];
        then
                echo "Error: Cannot connect to pelx"
                rm /var/lock/rsync-cache_plex_transmission
                return 1
        fi

        NB_SESSIONS=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/@size)' -)
        echo "----------------------------"
        echo "$NB_SESSIONS active(s) plex session(s):"
        echo "----------------------------"

# for each session
        for i in `seq $NB_SESSIONS`
        do
# get title
                ID=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/Video['$i']/@ratingKey)' -)
				TITLE=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/Video['$i']/@title)' -)
				TYPE=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/Video['$i']/@type)' -)
# eventually get serie info
				if [[ $TYPE = "episode" ]]
				then
					GRANDPARENTTITLE=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/Video['$i']/@grandparentTitle)' -)
					SEASON=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/Video['$i']/@parentIndex)' -)
					EPISODE=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/Video['$i']/@index)' -)
					PARENT_ID=$(echo $STATUS_SESSIONS  | xmllint --xpath 'string(//MediaContainer/Video['$i']/@parentRatingKey)' -)
					PARENT_NB_EPISODES=$(curl --silent http://${PLEX_HOST}/library/metadata/$PARENT_ID | xmllint --xpath 'string(//MediaContainer/Directory/@leafCount)' -)
					TITLE="${GRANDPARENTTITLE} Season ${SEASON} - Episode ${EPISODE}/${PARENT_NB_EPISODES}: $TITLE"
# update nb file to cache
					NB_FILES=1
					$PLEX_CACHE_NEXT_EPISODE && NB_FILES=2
					$PLEX_CACHE_SEASON_TILL_END && NB_FILES=$(( $PARENT_NB_EPISODES - $EPISODE + 1 ))
				else
					NB_FILES=1
				fi
                echo "$i/$NB_SESSIONS: $TITLE"
                for j in `seq $NB_FILES`
                do
# get file path
					PLEX_FILE=$(curl --silent http://${PLEX_HOST}/library/metadata/$ID | xmllint --xpath 'string(//MediaContainer/Video/Media/Part/@file)' -)
					FILE_TO_CACHE=$(echo ${PLEX_FILE} | sed 's|\"\"|\/|g' | sed 's|\"||g' | sed 's|\/data\/||')
					echo "Caching file $j/$NB_FILES: $FILE_TO_CACHE"
					STORAGE_FILE="${STORAGE_PATH}${FILE_TO_CACHE}"
					CACHE_FILE="${CACHE_PATH}${FILE_TO_CACHE}"
# and send to rsync
					RS_OPTIONS=""
					rsync_transfer "${STORAGE_FILE}" "${CACHE_FILE}" "${STORAGE_PATH}" "${CACHE_PATH}" "${RS_OPTIONS}"
					ID=$(( $ID + 1 ))
				done
				echo ""
        done
}

####################
# Delete old files #
####################
cleanup() {
		echo "---------------"
		echo "Cleaning cache:"
		echo "---------------"
# get free space and oldest files
		a=$(df -h | grep $CACHE_DISK | awk '{ printf "%d", $5 }')
		b=$CACHE_MIN_FREE_SPACE_PCT
		if [[ "$a" -ge "$b" ]];
		then
			echo "$a% space used, quota is $b%, cleaning:"
			echo "Scanning files..."
			find "${CACHE_PATH}" -type f -printf "%T@ %p\n" | sort -n | sed "s|`echo ${CACHE_PATH}`|%|g" | cut -d'%' -f2 | while read FILE_TO_CLEAN
			do
	# get free space
				a=$(df -h | grep $CACHE_DISK | awk '{ printf "%d", $5 }')
				b=$CACHE_MIN_FREE_SPACE_PCT
	# if free space not enough
				if [[ "$a" -ge "$b" ]];
				then
					echo "$a% space used, quota is $b%, uncaching $FILE_TO_CLEAN"
					STORAGE_FILE="${STORAGE_PATH}${FILE_TO_CLEAN}"
					CACHE_FILE="${CACHE_PATH}${FILE_TO_CLEAN}"
					RS_OPTIONS="--remove-source-files"
	# sync back cache to storage
					rsync_transfer "${CACHE_FILE}" "${STORAGE_FILE}" "${CACHE_PATH}" "${STORAGE_PATH}" "${RS_OPTIONS}"
				echo ""
				fi
			done
		fi
		a=$(df -h | grep $CACHE_DISK | awk '{ printf "%d", $5 }')
		b=$CACHE_MIN_FREE_SPACE_PCT
		echo "$a% space used, quota is $b%, nothing to do"
# prune empty directories from source dir
		echo "Cleaning empty directories..."
		find "${CACHE_PATH}" -type d -not -path '*/\.*' -empty -prune -exec rmdir --ignore-fail-on-non-empty {} \;
		echo ""
}

sys_checks
cleanup
$TRANSMISSION_ENABLED && transmission_cache
$PLEX_ENABLED && plex_cache
($TRANSMISSION_ENABLED || $PLEX_ENABLED) && cleanup


rm /var/lock/rsync-cache_plex_transmission
exit 0

