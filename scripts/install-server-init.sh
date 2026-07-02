#!/usr/bin/env bash
#
# Premier control plane (cp1) : initialise le cluster HA (etcd embarque)
# puis deploie kube-vip pour porter la VIP de l'API server.
#
# Args : $1=NODE_IP  $2=VIP  $3=K3S_TOKEN
set -euo pipefail

NODE_IP="$1"
VIP="$2"
K3S_TOKEN="$3"

# Version de kube-vip a epingler (stable). Derniere en date : v1.2.0.
KVVERSION="v1.0.4"

# --- helpers (integres : pas de dependance au dossier partage) ---------------
detect_interface() {
  ip -o -4 addr show | awk -v ip="$1" '$4 ~ "^"ip"/" {print $2; exit}'
}
wait_for_api() {
  local vip="$1"
  echo ">> Attente de l'API server sur ${vip}:6443 ..."
  until curl -k -s -o /dev/null "https://${vip}:6443/"; do sleep 3; done
  echo ">> API server joignable."
}
# -----------------------------------------------------------------------------

echo "== [cp1] Installation de k3s (cluster-init) =="
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --cluster-init \
    --token ${K3S_TOKEN} \
    --node-ip ${NODE_IP} \
    --tls-san ${VIP} \
    --tls-san ${NODE_IP} \
    --write-kubeconfig-mode 644" \
  sh -

echo "== [cp1] Attente que le noeud soit Ready =="
until k3s kubectl get nodes >/dev/null 2>&1; do sleep 3; done

echo "== [cp1] Deploiement de kube-vip (VIP control plane = ${VIP}) =="
INTERFACE="$(detect_interface "${NODE_IP}")"
echo ">> Interface detectee : ${INTERFACE}"

MANIFESTS=/var/lib/rancher/k3s/server/manifests
mkdir -p "${MANIFESTS}"

# RBAC officiel kube-vip
curl -sL https://kube-vip.io/manifests/rbac.yaml -o "${MANIFESTS}/kube-vip-rbac.yaml"

# Genere le DaemonSet kube-vip (mode ARP, election de leader, VIP du control plane).
k3s ctr image pull "ghcr.io/kube-vip/kube-vip:${KVVERSION}"
k3s ctr run --rm --net-host "ghcr.io/kube-vip/kube-vip:${KVVERSION}" vip \
  /kube-vip manifest daemonset \
    --interface "${INTERFACE}" \
    --address "${VIP}" \
    --inCluster \
    --taint \
    --controlplane \
    --arp \
    --leaderElection \
  > "${MANIFESTS}/kube-vip.yaml"

echo "== [cp1] Attente que la VIP reponde =="
wait_for_api "${VIP}"

echo "== [cp1] Termine. Cluster HA initialise. =="
echo ">> Kubeconfig disponible sur cp1 dans /etc/rancher/k3s/k3s.yaml"
echo ">> Recuperation depuis l'hote :"
echo "     vagrant ssh cp1 -c \"sudo sed 's/127.0.0.1/${VIP}/g' /etc/rancher/k3s/k3s.yaml\" > kubeconfig"
