#!/usr/bin/env bash
#
# Control planes additionnels (cp2, cp3) : rejoignent le cluster via la VIP.
#
# Args : $1=NODE_IP  $2=VIP  $3=K3S_TOKEN
set -euo pipefail

NODE_IP="$1"
VIP="$2"
K3S_TOKEN="$3"

wait_for_api() {
  local vip="$1"
  echo ">> Attente de l'API server sur ${vip}:6443 ..."
  until curl -k -s -o /dev/null "https://${vip}:6443/"; do sleep 3; done
  echo ">> API server joignable."
}

# On attend que cp1 ait publie la VIP avant de tenter de rejoindre.
wait_for_api "${VIP}"

echo "== [$(hostname)] Rejoint le cluster comme server (control plane) =="
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server \
    --token ${K3S_TOKEN} \
    --server https://${VIP}:6443 \
    --node-ip ${NODE_IP} \
    --tls-san ${VIP} \
    --tls-san ${NODE_IP} \
    --write-kubeconfig-mode 644" \
  sh -

echo "== [$(hostname)] Control plane ajoute. =="
