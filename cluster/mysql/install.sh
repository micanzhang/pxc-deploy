#!/bin/bash
#
# This script is used to install PXC cluster.
#

QCOS_ROOT=$(unset CDPATH && cd $(dirname "${BASH_SOURCE[0]}")/../.. && pwd)
cd $QCOS_ROOT

source "${QCOS_ROOT}/cluster/lib/init.sh"

function usage() {
    local rootpass=$(uuidgen)
    local sstpass=$(uuidgen)
    cat <<EOF
Usage: $(basename $0) [-h] -d <data_dir> -b <bind_address> -c <cluster_address> -p <password> -s <root_password> -e [development|production] [bootstrap]

Examples:

    # bootstrap PXC cluster 
    $(basename $0) -d /disk1/mysql -b 192.168.224.7 -c 192.168.224.7,192.168.224.17,192.168.224.27 -p $rootpass -s $sstpass -e production bootstrap

    # add node into PXC cluster
    $(basename $0) -d /disk1/mysql -b 192.168.224.17 -c 192.168.224.7,192.168.224.17,192.168.224.27 -p $rootpass -s $sstpass -e production
    $(basename $0) -d /disk1/mysql -b 192.168.224.27 -c 192.168.224.7,192.168.224.17,192.168.224.27 -p $rootpass -s $sstpass -e production

EOF
}

ENVIRONMENT=production
DATA_DIR=/var/lib/mysql
BIND_ADDRESS="0.0.0.0"
CLUSTER_ADDRESS=""
CLUSTER_NAME="pxc_cluster"
PASSWORD="root"
SST_PASSWORD="sstpass"

while getopts "h?d:b:c:e:p:s:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
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
    e)
        ENVIRONMENT="${OPTARG}"
    ;;
    p)
        PASSWORD="${OPTARG}"
    ;;
    s)
        SST_PASSWORD="${OPTARG}"
    ;;
    esac
done

shift $((OPTIND-1))
[ "$1" = "--" ] && shift

echo "ENVIRONMENT: $ENVIRONMENT"
echo "DATA_DIR: $DATA_DIR"
echo "BIND_ADDRESS: $BIND_ADDRESS"
echo "CLUSTER_ADDRESS: $CLUSTER_ADDRESS"
echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "PASSWORD: $PASSWORD"
echo "SST_PASSWORD: $SST_PASSWORD"
echo "ARGS: $@"

# setup percona repo
$QCOS_ROOT/cluster/mysql/repo.sh

# install mysql
if [[ "$GRAIN_OS" == "Ubuntu" ]]; then
    if ps -Cmysqld &>/dev/null; then
        echo "MySQL is running, exit."
        exit 1
    elif ! which mysqld &>/dev/null; then
        echo "Installing MySQL..."
        debconf-set-selections <<< "mysql-server percona-xtradb-cluster-server/root_password password ${PASSWORD}"
        debconf-set-selections <<< "mysql-server percona-xtradb-cluster-server/root_password_again password ${PASSWORD}"
        # Clear old my.cnf.
        test -f /etc/my.cnf && rm /etc/my.cnf
        # Disable performance_schema to make sure it's able to start MySQL on
        # low memory machine (for dpkg --configure).
        mkdir -p /etc/mysql/conf.d
        cat <<EOF > /etc/mysql/conf.d/hack.conf
[mysqld]
performance_schema=0
EOF
        apt-get install -y percona-xtradb-cluster-56
        apt-get install -y percona-toolkit
        apt-get install -y xinetd
        /etc/init.d/mysql stop
    else
        echo "MySQL is installed."
    fi
elif [[ "$GRAIN_OS" == "CentOS" ]]; then
    :
    yum install -y Percona-XtraDB-Cluster-56
    yum install -y xinetd
fi

# my.cnf

## clear default configuration files
test -f /etc/mysql/my.cnf && mv /etc/mysql/my.cnf /etc/mysql/my.cnf.defaults
$QCOS_ROOT/cluster/mysql/config.sh -d $DATA_DIR -p "$PASSWORD" -e $ENVIRONMENT \
  -b "$BIND_ADDRESS" \
  -n "$CLUSTER_NAME" \
  -c "$CLUSTER_ADDRESS" \
  -s "$SST_PASSWORD" > /etc/my.cnf

## install logrotate file
cat <<EOF > /etc/logrotate.d/mysql
${DATA_DIR}/mysql-slow.log {
    nocompress
    create 660 mysql mysql
    size 1G
    dateext
    missingok
    notifempty
    sharedscripts
    postrotate
       /usr/bin/mysql -e 'select @@global.long_query_time into @lqt_save; set global long_query_time=2000; select sleep(2); FLUSH LOGS; select sleep(2); set global long_query_time=@lqt_save;'
    endscript
    rotate 15
}
EOF

# check data dir
if test -d "$DATA_DIR"; then
    echo "$DATA_DIR exists, please clean before install MySQL database here."
    exit 1
fi
mkdir -p $DATA_DIR
chown mysql:mysql $DATA_DIR

# start
if [ "$1" == 'bootstrap' ]; then
    # init database
    mysql_install_db --user=mysql --basedir=/usr
    # start
    /etc/init.d/mysql bootstrap-pxc
    # change root password (default password is empty)
    mysqladmin --user=root --password='' password "$PASSWORD"
    # setup sst user
    mysql -e "GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'sstuser'@'localhost' IDENTIFIED BY '${SST_PASSWORD}';"
    # setup cluster check user
    mysql -e 'GRANT PROCESS ON *.* TO "clustercheckuser"@"localhost" IDENTIFIED BY "clustercheckpassword!";'
    # setup qcos user
    QCOS_USER=qnqcos
    QCOS_PASSWORD=$(uuidgen)
    mysql -e "GRANT ALL PRIVILEGES ON *.* TO $QCOS_USER@'%' IDENTIFIED BY '$QCOS_PASSWORD';"
    # do what mysql_secure_installation do
    # secure/remove_anonymous_users
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    # secure/remove_remote_root
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    # secure/remove_test_database
    mysql -e "DROP DATABASE test;"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
    # flush privileges
    mysql -e "FLUSH PRIVILEGES;"
else
    /etc/init.d/mysql start
fi

grep -q -F 'mysqlchk 9200/tcp' /etc/services || echo 'mysqlchk 9200/tcp # mysqlchk' >> /etc/services 
/etc/init.d/xinetd restart

if [[ "$GRAIN_OS" == "Ubuntu" ]]; then
    update-rc.d xinetd enable
    update-rc.d mysql enable
elif [[ "$GRAIN_OS" == "CentOS" ]]; then
    chkconfig xinetd on
    chkconfig mysql on
fi

$QCOS_ROOT/cluster/mysql/status.sh

qcos::log::status "QCOS Account: $QCOS_USER:$QCOS_PASSWORD"

#
# vim: ft=sh tw=0
#
