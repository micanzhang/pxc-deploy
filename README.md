# PXC Deployment

## Prerequisites

- Ubuntu 14.04

## Setup

```
vagrant up
```

You can run `export PXC_CLUSTER_NUM=<num>` to specify cluster num.

## Teardown

```
vagrant destroy -f
```

## Test

```
vagrant ssh ha
[ha] apt-get install -y sysbench
[ha] /vagrant/cluster/mysql/sysbench.sh prepare
[ha] /vagrant/cluster/mysql/sysbench.sh run
```

## References

- https://github.com/percona/xtradb-cluster-tutorial
- https://www.percona.com/doc/percona-xtradb-cluster/5.6/index.html
- https://www.percona.com/blog/tag/percona-xtradb-cluster/
