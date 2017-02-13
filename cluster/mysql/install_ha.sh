#!/bin/bash
#
# This script is used to install haproxy on client side.
#

QCOS_ROOT=$(unset CDPATH && cd $(dirname "${BASH_SOURCE[0]}")/../.. && pwd)
cd $QCOS_ROOT

source "${QCOS_ROOT}/cluster/lib/init.sh"

qcos::log::install_errexit

function usage() {
    cat <<EOF
Usage: $(basename $0) [-h] -c <cluster_address>

Examples:

    $(basename $0) -c 192.168.10.21,192.168.10.22,192.168.10.23

EOF
}

CLUSTER_ADDRESS=""

while getopts "h?c:i:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
        ;;
    c)
        CLUSTER_ADDRESS="${OPTARG}"
        ;;
    esac
done

if [ -z "$CLUSTER_ADDRESS" ]; then
    echo "You need specifiy cluster address with `-c`."
    usage
    exit -1
fi

$QCOS_ROOT/cluster/mysql/repo.sh

if [[ "$GRAIN_OS" == "Ubuntu" ]]; then
    apt-get install -y haproxy
    HAPROXY_CHROOT=/var/lib/haproxy
    sed -i -r "s/^(ENABLED)=.*/\1=1/" /etc/default/haproxy
elif [[ "$GRAIN_OS" == "CentOS" ]]; then
    yum install -y haproxy.x86_64
    HAPROXY_CHROOT=/usr/share/haproxy
fi

cat <<EOF > /etc/haproxy/haproxy.cfg
global
    user haproxy
    group haproxy
    chroot ${HAPROXY_CHROOT}
    daemon
    maxconn 8192
    log 127.0.0.1 local0 notice
    stats socket /var/run/haproxy.stat mode 666

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    retries 3
    option redispatch
    maxconn 2000
    timeout connect 5s
    timeout client  1800s
    timeout server  1800s

frontend pxc-front
    bind 127.0.0.1:3306
    default_backend pxc-backend

backend pxc-backend
    mode tcp
    balance leastconn
    option httpchk
EOF

for ip in $(tr -s ',' ' ' <<<"$CLUSTER_ADDRESS"); do
    cat <<EOF >> /etc/haproxy/haproxy.cfg
    server $ip $ip:3306 check port 9200 inter 5s rise 3 fall 3
EOF
done

/etc/init.d/haproxy restart

if [[ "$GRAIN_OS" == "Ubuntu" ]]; then
    update-rc.d haproxy defaults
elif [[ "$GRAIN_OS" == "CentOS" ]]; then
    chkconfig haproxy on
fi

# Only install mysql-client if no mysql installed on this machine,
# otherwise may stop running MySQL server.
if [[ "$GRAIN_OS" == "Ubuntu" ]]; then
    if ! `which mysql`; then
        apt-get install -y percona-xtradb-cluster-client-5.6
    fi
elif [[ "$GRAIN_OS" == "CentOS" ]]; then
    if ! `which mysql`; then
        yum install -y percona-xtradb-cluster-client-5.6
    fi
fi
