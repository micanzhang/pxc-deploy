#!/bin/bash
#
# Bash init script.
#
# 1. Change current working directory into maia home directory.
# 2. Load bash misc libraries.
#
# Usage:
#
#  source $(dirname $0)/relative/to/init.sh
#

QCOS_ROOT=$(unset CDPATH && cd $(dirname "${BASH_SOURCE[0]}")/../.. && pwd)
cd $QCOS_ROOT

source "${QCOS_ROOT}/cluster/lib/utils.sh"
source "${QCOS_ROOT}/cluster/lib/logging.sh"
source "${QCOS_ROOT}/cluster/lib/grains.sh"
