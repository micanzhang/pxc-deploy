#!/bin/bash

/etc/init.d/mysql stop
rm -r /disk1/mysql/*
rm /disk2/mysql_restore/ -r
#./cluster/mysql/restore.sh -w /disk2/mysql_restore/ -r /disk2/mysql_backup/incr/2016-03-10_20-46-36/2016-03-10_21-01-34
./cluster/mysql/restore.sh -w /disk2/mysql_restore/ -r /disk2/mysql_backup/incr/2016-03-10_19-18-56/2016-03-10_19-22-30/
#./cluster/mysql/restore.sh -w /disk2/mysql_restore/ -r /disk2/mysql_backup/incr/2016-03-10_20-46-36/2016-03-10_21-01-55
if [ $? -eq 0 ]; then
    /etc/init.d/mysql bootstrap-pxc
fi
