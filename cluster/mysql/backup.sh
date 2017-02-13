#!/bin/bash
#
# This script is used to backup MySQL with Percona Xtrabackup.
#
# Usage:
#
#   Run this script every minute.
#
# Structure:
#
#  full backup: /base/
#  incr backup: /incr/
#  backup logs: /logs/
#
# References:
#
#  - https://www.percona.com/doc/percona-xtrabackup/2.4/index.html
#

QCOS_ROOT=$(unset CDPATH && cd $(dirname "${BASH_SOURCE[0]}")/../.. && pwd)
cd $QCOS_ROOT

source "${QCOS_ROOT}/cluster/lib/init.sh"

qcos::log::install_errexit

function usage() {
    cat <<EOF
Usage: $(basename $0) -d <data_dir>

Examples:

    $(basename $0) -d /disk2/mysql_backup

EOF
}

function timestamp_from_backup_dir() {
    python -c 'import sys,time,datetime;
t = time.mktime(datetime.datetime.strptime(sys.argv[1],"%Y-%m-%d_%H-%M-%S").timetuple())
print(int(t))' $1
}

function should_create_incr_backup() {
    if [ -z "$1" ]; then
        return -1
    fi
    local timestamp=$(timestamp_from_backup_dir $1)
    if [ -z "$timestamp" ]; then
        return -2
    fi
    test "$(expr $timestamp + 3600)" -gt "$2"
}

function should_clean() {
    if [ -z "$1" ]; then
        return -1
    fi
    local timestamp=$(timestamp_from_backup_dir $1)
    if [ -z "$timestamp" ]; then
        return -2
    fi
    test "$(expr $timestamp + 3600 '*' 24 '*' 7)" -lt "$2"
}

function should_compress() {
    if [ -z "$1" ]; then
        return -1
    fi
    local timestamp=$(timestamp_from_backup_dir $1)
    if [ -z "$timestamp" ]; then
        return -2
    fi
    test "$(expr $timestamp + 3600 '*' 24)" -lt "$2"
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

BACKUP_DIR=""
MYSQL_OPTIONS="--defaults-file=$MYCNF_PATH --user=root"

while getopts "h?d:k:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
    ;;
    d)
        BACKUP_DIR="${OPTARG%/}"
    ;;
    esac
done

shift $((OPTIND-1))
[ "$1" = "--" ] && shift

if test -z "$BACKUP_DIR"; then
    qcos::log::error_exit "please specify backup dir with '-z' option"
fi

BACKUP_FULL_DIR="$BACKUP_DIR/full"
BACKUP_INCR_DIR="$BACKUP_DIR/incr"
BACKUP_LOGS_DIR="$BACKUP_DIR/logs"
BACKUP_LOCK="/var/run/qcos.mysql.backup.lock"
BACKUP_TIME=$(date +%s)
BACKUP_INNOBACKUPEX_FULL_LOGFILE="$BACKUP_DIR/logs/innobackupex.full.$(date +%Y%m%d_%H%M%S -d @$BACKUP_TIME).log"
BACKUP_INNOBACKUPEX_INCR_LOGFILE="$BACKUP_DIR/logs/innobackupex.incr.$(date +%Y%m%d_%H%M%S -d @$BACKUP_TIME).log"

echo "BACKUP_DIR: $BACKUP_DIR"
echo "BACKUP_FULL_DIR: $BACKUP_FULL_DIR"
echo "BACKUP_INCR_DIR: $BACKUP_INCR_DIR"
echo "BACKUP_LOGS_DIR: $BACKUP_LOGS_DIR"
echo "BACKUP_LOCK: $BACKUP_LOCK"
echo "BACKUP_TIME: $BACKUP_TIME"
echo "BACKUP_INNOBACKUPEX_FULL_LOGFILE: $BACKUP_INNOBACKUPEX_FULL_LOGFILE"
echo "BACKUP_INNOBACKUPEX_INCR_LOGFILE: $BACKUP_INNOBACKUPEX_INCR_LOGFILE"

# run with lock
exec 9> "$BACKUP_LOCK"
flock -n 9 || { echo "Already an instance running, exit."; exit; }

(

# check
if ! ps -Cmysqld &>/dev/null; then
    qcos::log::error_exit "MySQL is not running."
fi

test -d "$BACKUP_DIR" || mkdir -p "$BACKUP_DIR"
test -d "$BACKUP_FULL_DIR" || mkdir -p "$BACKUP_FULL_DIR"
test -d "$BACKUP_INCR_DIR" || mkdir -p "$BACKUP_INCR_DIR"
test -d "$BACKUP_LOGS_DIR" || mkdir -p "$BACKUP_LOGS_DIR"

if ! `echo 'exit' | mysql`; then
    qcos::log::error_exit "failed to connect to mysql server."
fi

if ! `which innobackupex &>/dev/null`; then
    qcos::log::error_exit "innobackupex not found, please install Percona Xtrabackup."
fi

## find latest full backup
FULL_LATEST=$(find "$BACKUP_FULL_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1)
echo "FULL_LATEST: $FULL_LATEST"

if should_create_incr_backup "$FULL_LATEST" "$BACKUP_TIME"; then
    qcos::log::status "New increment backup."

    BACKUP_INCR_DIR_CURR="$BACKUP_INCR_DIR/$FULL_LATEST"
    test -d "$BACKUP_INCR_DIR_CURR" || mkdir "$BACKUP_INCR_DIR_CURR"

    BACKUP_INCR_DIR_CURR_LATEST=$(find "$BACKUP_INCR_DIR_CURR" -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1)
    if [ -z "$BACKUP_INCR_DIR_CURR_LATEST" ]; then
        # This is first increment backup of current full backup.
        BACKUP_INCR_BASE_DIR="$BACKUP_FULL_DIR/$FULL_LATEST"
    else
        BACKUP_INCR_BASE_DIR=$BACKUP_INCR_DIR_CURR_LATEST
    fi
    echo innobackupex $MYSQL_OPTIONS --slave-info \
        --incremental "$BACKUP_INCR_DIR_CURR" \
        --incremental-basedir "$BACKUP_INCR_BASE_DIR"
    innobackupex $MYSQL_OPTIONS --slave-info \
        --incremental "$BACKUP_INCR_DIR_CURR" \
        --incremental-basedir "$BACKUP_INCR_BASE_DIR" \
        &> $BACKUP_INNOBACKUPEX_INCR_LOGFILE

    if [ $? -eq 0 ]; then
        qcos::log::status "Incremental backup ok."
        echo ""
        echo "------ LAST OUTPUT FROM $BACKUP_INNOBACKUPEX_INCR_LOGFILE ------"
        tail -n 5 $BACKUP_INNOBACKUPEX_INCR_LOGFILE
        echo ""
    else
        qcos::log::status "Incremental backup failed."
        echo ""
        echo "------ ERROR OUTPUT FROM $BACKUP_INNOBACKUPEX_INCR_LOGFILE ------"
        cat $BACKUP_INNOBACKUPEX_INCR_LOGFILE
        echo ""
        exit 1
    fi
else
    qcos::log::status "New full backup..."
    BACKUP_FULL_DIR_CURR="$BACKUP_FULL_DIR/$(date +%Y-%m-%d_%H-%M-%S -d @$BACKUP_TIME)"
    echo innobackupex $MYSQL_OPTIONS --no-timestamp \
        --slave-info $BACKUP_FULL_DIR_CURR
    innobackupex $MYSQL_OPTIONS --no-timestamp \
        --slave-info $BACKUP_FULL_DIR_CURR \
        &> $BACKUP_INNOBACKUPEX_FULL_LOGFILE

    # Finally, the binary qcos::log::info position will be printed to STDERR and innobackupex will exit returning 0 if all went OK.
    if [ $? -eq 0 ]; then
        qcos::log::status "Full backup ok."
        echo ""
        echo "------ LAST OUTPUT FROM $BACKUP_INNOBACKUPEX_FULL_LOGFILE ------"
        tail -n 5 $BACKUP_INNOBACKUPEX_FULL_LOGFILE
        echo ""
    else
        qcos::log::status "Full backup failed."
        echo ""
        echo "------ ERROR OUTPUT FROM $BACKUP_INNOBACKUPEX_FULL_LOGFILE ------"
        cat $BACKUP_INNOBACKUPEX_FULL_LOGFILE
        echo ""
        exit 1
    fi
fi

# clean
function rm_with_log() {
    qcos::log::status "Removing $1"
    rm -r "$1"
}

for f in $(find $BACKUP_FULL_DIR -mindepth 1 -maxdepth 1 -printf "%P\n" | sort); do
    if [[ "$f" =~ \.tar\.gz$ ]]; then
        dir=${f%%.*}
        compressed=true
    elif [[ "$f" =~ \.tar$ ]]; then
        dir=${f%%.*}
        compressed=false
    else
        dir=$f
        compressed=false
    fi
    if should_clean "$dir" $BACKUP_TIME; then
        # remove full directory or compressed file
        rm_with_log "$BACKUP_FULL_DIR/$f"
    elif [[ "$compressed" == "false" ]] && should_compress "$dir" $BACKUP_TIME; then
        qcos::log::status "Compressing $BACKUP_FULL_DIR/$f to $BACKUP_FULL_DIR/$dir.tar.gz..."
        if [[ "$f" =~ \.tar$ ]]; then
            gzip "$BACKUP_FULL_DIR/$f"
        else
            tar -czf "$BACKUP_FULL_DIR/$dir.tar.gz" -C "$BACKUP_FULL_DIR" "$dir"
            rm_with_log "$BACKUP_FULL_DIR/$f"
        fi
        if [ $? -eq 0 ]; then
            qcos::log::status "Compressing ok."
        fi
    fi
done

for f in $(find $BACKUP_INCR_DIR -mindepth 1 -maxdepth 1 -printf "%P\n" | sort); do
    if should_clean "$f" $BACKUP_TIME; then
        rm_with_log "$BACKUP_INCR_DIR/$f"
    fi
done

) 9<&-

#
# vim: ft=sh tw=0
#
