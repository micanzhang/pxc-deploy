#!/bin/bash

function is_pkg_installed() {
    dpkg-query --showformat='${Status}\n' -W "$1" 2>/dev/null | grep ' installed$' &>/dev/null
}

function is_module_loaded() {
    lsmod | awk '{ print $1 }' | grep ^$1$ &>/dev/null
}

#
# Examples: run_with_retries 3 git pull
#
function run_with_retries() {
    local n=${1:-0}
    local code=0
    until [ $n -le 0 ]; do
        ${@:2}
        code=$?
        if [ $code -eq 0 ]; then
            return 0
        fi
        n=$[$n-1]
    done
    return $code
}


#
# Check directory is empty or not.
#
# See http://stackoverflow.com/a/20456797/288089.
#
# Usage: is_dir_empty /path/to/dir
#
function is_dir_empty() {
    local target=$1
    ! find "$target" -mindepth 1 -print -quit | grep -q .
}

# Usage:
#   version_compare "1.2" "1.3"
#   echo $?
#
# Exit status:
#   0: =
#   1: >
#   2: <
#
# See http://stackoverflow.com/a/4025065/288089.
#
function version_compare() {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

function uniq_path() {
    echo "$1" | awk -F: '{
        for (i=1;i<=NF;i++) {
            if (!x[$i]++) {
                # first one is definitely non-duplicated one
                if (i != 1) printf(":");
                printf("%s", $i);
            }
        }
    }'
}

function append_path() {
    if eval test -z "\"\$$1\""; then
        eval "$1=$2"
        return
    fi
    if ! eval test -z "\"\${$1##*:$2:*}\"" -o -z "\"\${$1%%*:$2}\"" -o -z "\"\${$1##$2:*}\"" -o -z "\"\${$1##$2}\"" ; then
        eval "$1=\$$1:$2"
        eval "$1=\$(uniq_path \$$1)"
        export $1
    fi
}

function prepend_path() {
    if eval test -z "\"\$$1\""; then
        eval "$1=$2"
        return
    fi
    if ! eval test -z "\"\${$1##*:$2:*}\"" -o -z "\"\${$1%%*:$2}\"" -o -z "\"\${$1##$2:*}\"" -o -z "\"\${$1##$2}\"" ; then
        eval "$1=$2:\$$1"
        eval "$1=\$(uniq_path \$$1)"
        export $1
    fi
}
