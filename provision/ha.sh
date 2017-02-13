#!/bin/bash

ROOT=/vagrant
cd $ROOT

$ROOT/cluster/mysql/install_ha.sh -c 192.168.10.21,192.168.10.22,192.168.10.23 -i 1

if [[ "$GRAIN_OS" == "Ubuntu" ]]; then
    apt-get install -y sysbench
elif [[ "$GRAIN_OS" == "CentOS" ]]; then
    yum install -y sysbench
fi
