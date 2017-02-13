#!/bin/bash

ROOT=/vagrant
cd $ROOT

source $ROOT/cluster/lib/grains.sh

# timezone
timedatectl set-timezone Asia/Shanghai

sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
sed -i '/security.ubuntu.com/d' /etc/apt/sources.list
sed -i '/^deb-src /d' /etc/apt/sources.list
