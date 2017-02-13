#!/bin/bash
#
# See https://www.percona.com/docs/wiki/benchmark:sysbench:olpt.lua.
# See https://github.com/akopytov/sysbench.
#

#mysql -h 127.0.0.1 -ucu -pcu -e 'drop table clusterup.sbtest1'

if [ -z "$1" ]; then
    echo "Usage: $0 [prepare|run|cleanup]"
    exit
fi

sysbench \
    --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
    --mysql-host=127.0.0.1 \
    --mysql-port=3306 \
    --mysql-user=cu \
    --mysql-password=cu \
    --mysql-db=clusterup \
    --mysql-table-engine=innodb \
    --mysql-ignore-errors=all \
    --oltp-table-size=250000 \
    --report-interval=1 \
    --max-requests=0 \
    --tx-rate=10 \
    --num-threads=10 \
    $1
