#!/usr/bin/env bash
#
# Workers (w1, w2, w3) : rejoignent le cluster comme agents via la VIP.
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

wait_for_api "${VIP}"

echo "== [$(hostname)] Rejoint le cluster comme agent (worker) =="
curl -sfL https://get.k3s.io | \
  K3S_URL="https://${VIP}:6443" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="agent --node-ip ${NODE_IP}" \
  sh -

echo "== [$(hostname)] Worker ajoute. =="
