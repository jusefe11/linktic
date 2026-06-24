#!/bin/bash
# Reproducible k3s SERVER install (run on the server node).
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init \
  --flannel-backend=none --disable-network-policy --disable=traefik \
  --node-ip=172.31.9.150 --advertise-address=172.31.9.150 \
  --node-external-ip=100.48.22.237 --tls-san=100.48.22.237" sh -
