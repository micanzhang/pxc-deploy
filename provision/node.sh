#!/bin/bash

ROOT=/vagrant
cd $ROOT

source $ROOT/cluster/lib/grains.sh

if [ $# -lt 4 ]; then
    echo "Usage: $0 <num> <ip> <password> <sst_password>"
    exit 1
fi

# clear installed packages
if [[ "$GRAIN_OS" == "Ubuntu" ]]; then
    debconf-set-selections <<< "mysql-server percona-xtradb-cluster-server-5.6/postrm_remove_databases boolean true"
    dpkg --purge --force-depends percona-xtradb-cluster-56
    dpkg --purge --force-depends percona-xtradb-cluster-server-5.6
    apt-get autoremove -y
elif [[ "$GRAIN_OS" == "CentOS" ]]; then
    # TODO
    :
fi

# clear database
test -d /disk1/mysql && rm -r /disk1/mysql

# install & start
if [ "$1" == '1' ]; then
    $ROOT/cluster/mysql/install.sh -d /disk1/mysql -b $2 -c 192.168.10.21,192.168.10.22,192.168.10.23 -e development -p $3 -s $4 bootstrap
    # create test database
    mysql -e 'CREATE DATABASE clusterup;'
    mysql -e 'GRANT ALL ON clusterup.* TO "cu"@"%" IDENTIFIED BY "cu";'
    mysql -e "FLUSH PRIVILEGES;"
else
    $ROOT/cluster/mysql/install.sh -d /disk1/mysql -b $2 -c 192.168.10.21,192.168.10.22,192.168.10.23 -e development -p $3 -s $4
fi
