#!/bin/bash
#
# This script is used to restore MySQL with Percona Xtrabackup.
#
# References:
#
#  - https://www.percona.com/doc/percona-xtrabackup/2.4/index.html

QCOS_ROOT=$(unset CDPATH && cd $(dirname "${BASH_SOURCE[0]}")/../.. && pwd)
cd $QCOS_ROOT

source "${QCOS_ROOT}/cluster/lib/init.sh"

function usage() {
    cat <<EOF
Usage: $(basename $0) -w <working_dir> -r <restore_dir> [-m <user_memory>]

Examples:

    $(basename $0) -w /disk2/mysql_restore/ -r /disk2/mysql_backup/full/2016-03-10_17-26-05 -m 1G
    $(basename $0) -w /disk2/mysql_restore/ -r /disk2/mysql_backup/incr/2016-03-10_17-26-05/2016-03-10_17-26-16/ -m 1G

EOF
}

function is_incr_backup() {
    local infofile="$1/xtrabackup_info"
    if ! test -f "$infofile"; then
        return -1
    fi
    grep -P '^incremental\s+=\s+Y$' "$infofile" &> /dev/null
}

function datadir_from_cnf() {
    awk  '/datadir/ { print $3 }' $1
}

function detect_mycnf_path() {
   for f in /etc/my.cnf /etc/mysql/my.cnf; do
       if test -f $f; then
           echo $f
           break
       fi
   done
}

MYCNF_PATH=$(detect_mycnf_path)
if [ -z "$MYCNF_PATH" ]; then
   qcos::error_exit "failed to detect my.cnf path"
fi
WORKING_DIR=""
RESTORE_DIR=""
USE_MEMORY="128M"

while getopts "h?r:w:m:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
    ;;
    w)
        WORKING_DIR="${OPTARG%/}"
    ;;
    r)
        RESTORE_DIR="${OPTARG%/}"
    ;;
    m)
        USE_MEMORY="${OPTARG}"
    ;;
    esac
done

shift $((OPTIND-1))
[ "$1" = "--" ] && shift

RESTORE_LOCK="/var/run/qcos.mysql.restore.lock"
RESTORE_INNORESTOREEX_INCRREPLAY_LOGFILE="$WORKING_DIR/innobackupex.prepare.$(date +%Y%m%d_%H%M%S).log"
RESTORE_INNORESTOREEX_PREPARE_LOGFILE="$WORKING_DIR/innobackupex.prepare.$(date +%Y%m%d_%H%M%S).log"
RESTORE_INNORESTOREEX_RESTORE_LOGFILE="$WORKING_DIR/innobackupex.restore.$(date +%Y%m%d_%H%M%S).log"
DATADIR=$(datadir_from_cnf $MYCNF_PATH)
MYSQL_OPTIONS="--defaults-file=$MYCNF_PATH --user=root"
APPLY_LOG_OPTIONS="--use-memory=$USE_MEMORY"

echo "WORKING_DIR: $WORKING_DIR"
echo "RESTORE_DIR: $RESTORE_DIR"
echo "RESTORE_LOCK: $RESTORE_LOCK"
echo "MYSQL_OPTIONS: $MYSQL_OPTIONS"
echo "APPLY_LOG_OPTIONS: $APPLY_LOG_OPTIONS"
echo "RESTORE_INNORESTOREEX_PREPARE_LOGFILE: $RESTORE_INNORESTOREEX_PREPARE_LOGFILE"
echo "RESTORE_INNORESTOREEX_RESTORE_LOGFILE: $RESTORE_INNORESTOREEX_RESTORE_LOGFILE"
echo ""

# run with lock
exec 9> "$RESTORE_LOCK"
flock -n 9 || { echo "Already an instance running, exit."; exit; }

(

# check
if test -z "$RESTORE_DIR" || test -z "$WORKING_DIR"; then
    usage
    exit -1
fi

if ! test -d "$RESTORE_DIR"; then
    qcos::log::error_exit "restore dir '$RESTORE_DIR' does not exist."
fi

test -d "$WORKING_DIR" || mkdir -p "$WORKING_DIR"

if ! is_dir_empty "$WORKING_DIR"; then
    qcos::log::error_exit "working dir '$WORKING_DIR' is not empty."
fi

if ! is_dir_empty "$DATADIR"; then
    qcos::log::error_exit "datadir '$DATADIR' is not empty"
fi

RESTORE_INCR_DIRS=()

if is_incr_backup "$RESTORE_DIR"; then
    qcos::log::status "Restore incremental backup from: $RESTORE_DIR"
    RESTORE_INCR_DIR_LAST=$(basename "$RESTORE_DIR")
    RESTORE_INCR_DIR=$(cd "$RESTORE_DIR"/..; pwd)
    RESTORE_BASE_DIR=${RESTORE_INCR_DIR/incr/full}
    for d in $(find "$RESTORE_INCR_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -n); do
        RESTORE_INCR_DIRS+=($d)
        if [[ "$d" == "$RESTORE_INCR_DIR_LAST" ]]; then
            break
        fi
    done
else
    RESTORE_BASE_DIR="$RESTORE_DIR"
    qcos::log::status "Restore full backup from: $RESTORE_DIR"
fi

qcos::log::status "RESTORE_BASE_DIR: $RESTORE_BASE_DIR"

# Syncing base dir to working dir.
# Notes: base dir may be gzipped.
if test -d "$RESTORE_BASE_DIR"; then
    qcos::log::status "Rsyncing $RESTORE_BASE_DIR to $WORKING_DIR..."
    rsync -av "$RESTORE_BASE_DIR/" "$WORKING_DIR/" &> "$WORKING_DIR/rsync.log"
    if [ $? -eq 0 ]; then
        qcos::log::status "Rsyncing ok."
    else
        qcos::log::error_exit "Rsyncing failed."
    fi
elif test -f "$RESTORE_BASE_DIR.tar.gz"; then
    gziped_tar="$RESTORE_BASE_DIR.tar.gz"
    qcos::log::status "Extracting $gziped_tar to $WORKING_DIR..."
    tar -xvf "$gziped_tar" -C "$WORKING_DIR" --strip 1 &> "$WORKING_DIR/tar.extract.log"
    if [ $? -eq 0 ]; then
        qcos::log::status "Extracting done."
    else
        qcos::log::error_exit "Extracting failed."
    fi
else
    qcos::log::error_exit "Could not find contents of $RESTORE_BASE_DIR."
fi

if is_incr_backup "$RESTORE_DIR"; then
    # Preparing incremental backups is a bit different than full ones. 
    # First, only the committed transactions must be replayed on each backup.
    qcos::log::status "Replaying on the committed transactions on base dir..."
    echo innobackupex $MYSQL_OPTIONS \
        --apply-log --redo-only \
        $APPLY_LOG_OPTIONS $WORKING_DIR
    innobackupex $MYSQL_OPTIONS \
        --apply-log --redo-only \
        $APPLY_LOG_OPTIONS $WORKING_DIR \
        &>> $RESTORE_INNORESTOREEX_INCRREPLAY_LOGFILE
    if [ $? -eq 0 ]; then
        qcos::log::status "Replaying ok."
    else
        qcos::log::error_exit "Replaying failed."
    fi
    for incr in "${RESTORE_INCR_DIRS[@]}"; do
        if [[ "$incr" == "$RESTORE_INCR_DIR_LAST" ]]; then
            qcos::log::status "Replaying on the committed transactions on incremental dir ($incr, the last)..."
            echo innobackupex $MYSQL_OPTIONS \
                --apply-log \
                $APPLY_LOG_OPTIONS $WORKING_DIR
            innobackupex $MYSQL_OPTIONS \
                --apply-log \
                $APPLY_LOG_OPTIONS $WORKING_DIR \
                &>> $RESTORE_INNORESTOREEX_INCRREPLAY_LOGFILE
            if [ $? -eq 0 ]; then
                qcos::log::status "Replaying ok."
            else
                qcos::log::error_exit "Replaying failed."
            fi
        else
            qcos::log::status "Replaying on the committed transactions on incremental dir ($incr)..."
            echo innobackupex $MYSQL_OPTIONS \
                --apply-log --redo-only \
                $APPLY_LOG_OPTIONS $WORKING_DIR
            innobackupex $MYSQL_OPTIONS \
                --apply-log --redo-only \
                $APPLY_LOG_OPTIONS $WORKING_DIR \
                &>> $RESTORE_INNORESTOREEX_INCRREPLAY_LOGFILE
            if [ $? -eq 0 ]; then
                qcos::log::status "Replaying ok."
            else
                qcos::log::error_exit "Replaying failed."
            fi
        fi
    done
fi

qcos::log::status "Preparing backup to roll back the uncommitted transactions..."
echo innobackupex $MYSQL_OPTIONS \
    --apply-log $APPLY_LOG_OPTIONS $WORKING_DIR
innobackupex $MYSQL_OPTIONS \
    --apply-log $APPLY_LOG_OPTIONS $WORKING_DIR \
    &> $RESTORE_INNORESTOREEX_PREPARE_LOGFILE
if [ $? -eq 0 ]; then
    qcos::log::status "Preparing ok."
else
    qcos::log::error_exit "Preparing failed."
fi

qcos::log::status "Restoring..."

echo innobackupex $MYSQL_OPTIONS --ibbackup=xtrabackup \
    --copy-back $WORKING_DIR
innobackupex $MYSQL_OPTIONS --ibbackup=xtrabackup \
    --copy-back $WORKING_DIR \
    &> $RESTORE_INNORESTOREEX_RESTORE_LOGFILE
if [ $? -eq 0 ]; then
    qcos::log::status "Restoring ok."
else
    qcos::log::error_exit "Restoring error."
fi

chown -R mysql:mysql "$DATADIR"

qcos::log::status "$RESTORE_DIR restored to $DATADIR successfully."
qcos::log::status "You are able to start mysql now."
qcos::log::status "Working directory '$WORKING_DIR' you can removed now."

) 9<&-

#
# vim: ft=sh tw=0
#
