#!/bin/bash
#
# This script is used to generate MySQL configuration file.
#
# References:
#
# - https://tools.percona.com/wizard
#

QCOS_ROOT=$(unset CDPATH && cd $(dirname "${BASH_SOURCE[0]}")/../.. && pwd)
cd $QCOS_ROOT

source "${QCOS_ROOT}/cluster/lib/init.sh"

function usage() {
    cat <<EOF
Usage: $(basename $0) -d <data_dir> -p <password> -e <production|development> -b <bind_address> -n <cluste_name> -c <cluster_address> -s <sst_password>

Examples:

    $(basename $0) -d /disk1/mysql -p password -e production -b 192.168.160.1 -n pxc_cluster -c 192.168.160.1,192.168.160.2,192.168.160.3 -s <sst_password>

EOF
}

ENVIRONMENT=production
DATA_DIR=/var/lib/mysql
PASSWORD=root
BIND_ADDRESS="0.0.0.0"
CLUSTER_ADDRESS=""
CLUSRER_NAME="pxc_cluster"
SST_PASSWORD="s3cret"

while getopts "h?p:e:d:b:c:n:s:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
        ;;
    p)
        PASSWORD="$OPTARG"
        ;;
    e)
        ENVIRONMENT="$OPTARG"
        ;;
    d)
        DATA_DIR="${OPTARG%/}"
        ;;
    b)
        BIND_ADDRESS="${OPTARG}"
        ;;
    c)
        CLUSTER_ADDRESS="${OPTARG}"
        ;;
    n)
        CLUSTER_NAME="${OPTARG}"
        ;;
    s)
        SST_PASSWORD="${OPTARG}"
        ;;
    esac
done

function find_libgalera_ssm_path() {
    for f in /usr/lib/libgalera_smm.so /usr/lib64/libgalera_smm.so; do
        if test -e "$f"; then
        echo "$f"
        return
        fi
    done
}

function calc_innodb_buffer_pool_size() {
    local m=$(($GRAIN_MEM_TOTAL / 2 / 1024 / 1024 / 1024))
    if [[ $m -lt 1 ]]; then
        m=1
    fi
    echo "${m}G"
}

echo "ENVIRONMENT: $ENVIRONMENT" 1>&2
echo "DATA_DIR: $DATA_DIR" 1>&2
echo "PASSWORD: $PASSWORD" 1>&2
echo "BIND_ADDRESS: $BIND_ADDRESS" 1>&2
echo "CLUSTER_NAME: $CLUSTER_NAME" 1>&2
echo "CLUSTER_ADDRESS: $CLUSTER_ADDRESS" 1>&2
echo "SST_PASSWORD: $SST_PASSWORD" 1>&2

LIBGALERA_SSM_PATH=$(find_libgalera_ssm_path)
echo "LIBGALERA_SSM_PATH: $LIBGALERA_SSM_PATH" 1>&2
if [ -z "$LIBGALERA_SSM_PATH" ]; then
    echo "libgalera_smm.so not found"
    exit 1
fi

INNODB_BUFFER_SIZE="32M"
INNODB_LOGFILE_SIZE="32M"
MAX_CONNECTIONS="128"
TABLE_DEFINITION_CACHE="128"
TABLE_OPEN_CACHE="128"
if [[ "$ENVIRONMENT" == "development" ]]; then
    :
elif [[ "$ENVIRONMENT" == "production" ]]; then
    INNODB_BUFFER_SIZE="$(calc_innodb_buffer_pool_size)"
    INNODB_LOGFILE_SIZE="512M"
    MAX_CONNECTIONS="4096"
    TABLE_DEFINITION_CACHE="1024"
    TABLE_OPEN_CACHE="2048"
else
    usage
    exit 0
fi

RUN_DIR="/var/run/mysqld"

cat <<EOF
[client]

# CLIENT #
user                           = root
password                       = ${PASSWORD}
port                           = 3306
socket                         = ${RUN_DIR}/mysql.sock

[mysqld]

# GENERAL #
user                           = mysql
default-storage-engine         = InnoDB
socket                         = ${RUN_DIR}/mysql.sock
pid-file                       = ${RUN_DIR}/mysql.pid
bind-address                   = ${BIND_ADDRESS}

# GELERA #

# Path to Galera library
wsrep_provider                 = ${LIBGALERA_SSM_PATH}
wsrep_provider_options         = "gcache.size=512M"

# Cluster connection URL contains the IPs of all possible nodes
wsrep_cluster_address          = gcomm://${CLUSTER_ADDRESS}

# Node address
wsrep_node_address             = ${BIND_ADDRESS}

# SST method
wsrep_sst_method               = xtrabackup-v2

# Cluster name
wsrep_cluster_name             = ${CLUSTER_NAME}

# Authentication for SST method
wsrep_sst_auth                 = "sstuser:${SST_PASSWORD}"

# MyISAM #
key-buffer-size                = 32M
myisam-recover                 = FORCE,BACKUP

# SAFETY #
max-allowed-packet             = 16M
max-connect-errors             = 1000000
skip-name-resolve
sql-mode                       = NO_ENGINE_SUBSTITUTION
sysdate-is-now                 = 1
innodb                         = FORCE
innodb-strict-mode             = 1

# DATA STORAGE #
datadir                        = ${DATA_DIR}

# BINARY LOGGING #
log-bin                        = ${DATA_DIR}/mysql-bin
expire-logs-days               = 14
sync-binlog                    = 1
# In order for Galera to work correctly binlog format should be ROW
binlog_format                  = ROW
# Uncomment following lines if you want to replicate asynchronously from a
# non-member of the cluster.
# Note: servier_id should be unique.
#server_id                      = ${SERVER_ID}
#log_slave_updates
#relay-log                      = mysql-relay-bin

# CACHES AND LIMITS #
tmp-table-size                 = 32M
max-heap-table-size            = 32M
query-cache-type               = 0
query-cache-size               = 0
max-connections                = ${MAX_CONNECTIONS}
thread-cache-size              = 100
open-files-limit               = 65535
table-definition-cache         = ${TABLE_DEFINITION_CACHE}
table-open-cache               = ${TABLE_OPEN_CACHE}

# INNODB #
innodb-flush-method            = O_DIRECT
innodb-log-files-in-group      = 2
innodb-log-file-size           = ${INNODB_LOGFILE_SIZE}
innodb-flush-log-at-trx-commit = 1
innodb-file-per-table          = 1
innodb-buffer-pool-size        = ${INNODB_BUFFER_SIZE}

# This changes how InnoDB autoincrement locks are managed and is a requirement
# for Galera.
innodb_autoinc_lock_mode       = 2

# LOGGING #
log-error                      = ${DATA_DIR}/mysql-error.log
log-queries-not-using-indexes  = 1
slow-query-log                 = 1
slow-query-log-file            = ${DATA_DIR}/mysql-slow.log

# MISC #
explicit_defaults_for_timestamp

EOF
