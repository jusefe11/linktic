#!/bin/bash
# Run on EVERY node BEFORE installing Calico. Aligns CNI dirs so the Calico operator
# (writes to /etc/cni/net.d + /opt/cni/bin) and k3s containerd (reads its own dirs) agree.
set -e
sudo mkdir -p /etc/cni/net.d /opt/cni /var/lib/rancher/k3s/agent/etc/cni
[ -L /var/lib/rancher/k3s/agent/etc/cni/net.d ] || { sudo rm -rf /var/lib/rancher/k3s/agent/etc/cni/net.d; sudo ln -sfn /etc/cni/net.d /var/lib/rancher/k3s/agent/etc/cni/net.d; }
[ -e /opt/cni/bin ] || sudo ln -sfn /var/lib/rancher/k3s/data/current/bin /opt/cni/bin
