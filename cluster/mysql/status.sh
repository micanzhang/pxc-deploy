#!/bin/bash

mysql -te "show status like 'wsrep%';" | egrep 'wsrep_cluster_size|wsrep_cluster_status|wsrep_connected|wsrep_local_state|Variable_name|\+'

curl http://localhost:9200/
