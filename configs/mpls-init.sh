#!/bin/bash
# Enable MPLS kernel settings on startup
sysctl -w net.mpls.platform_labels=100000
for iface in lo eth1 eth2 eth3 eth4 eth5; do
  sysctl -w net.mpls.conf.$iface.input=1 2>/dev/null
done
# Start FRR
exec /usr/lib/frr/docker-start
