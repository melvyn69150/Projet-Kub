# k8s-platform

Plateforme Kubernetes de bout en bout montée en local (VMware Workstation), pour un
projet d'école. Le livrable est **le code** : tout est déclaratif et versionné ici, la
documentation est en Markdown dans `docs/`.

## Contraintes couvertes

| Contrainte              | Solution                                   | Phase |
|-------------------------|--------------------------------------------|-------|
| **HA**                  | k3s 3 control planes (etcd quorum) + kube-vip | 1  |
| **Déploiement auto** 🎁 | GitOps avec Argo CD (app-of-apps)          | 2     |
| **Observabilité**       | kube-prometheus-stack + Loki               | 3     |
| **Autoscaling**         | metrics-server + HPA + KEDA                | 4     |
| **Backup**              | Velero + MinIO + snapshots etcd            | 5     |
| **Multicluster** 🎁     | 2ᵉ cluster + Argo CD ApplicationSets       | 6     |

🎁 = bonus

## Stack

k3s · kube-vip · Argo CD · Prometheus/Grafana/Alertmanager · Loki · KEDA · Velero · MinIO

## Démarrage rapide

```powershell
# Prérequis : VMware Workstation + Vagrant + Vagrant VMware Utility
vagrant plugin install vagrant-vmware-desktop
vagrant up
$env:KUBECONFIG = "$PWD\kubeconfig"
kubectl get nodes -o wide
```

Détails complets : [`docs/01-vms-k3s-ha.md`](docs/01-vms-k3s-ha.md).

## Arborescence

```
k8s-platform/
├── Vagrantfile            # provisionne les 6 VMs (VMware) + k3s HA
├── scripts/               # installation k3s (server-init / server / agent) + kube-vip
├── docs/                  # le guide, phase par phase
│   └── 01-vms-k3s-ha.md
└── kubeconfig             # généré au 1er `vagrant up` (pointé sur la VIP)
```

## Roadmap

- [x] **Phase 1** — VMs automatisées + k3s HA + VIP
- [ ] **Phase 2** — Argo CD (GitOps, app-of-apps)
- [ ] **Phase 3** — Observabilité
- [ ] **Phase 4** — Autoscaling
- [ ] **Phase 5** — Backup
- [ ] **Phase 6** — Multicluster
