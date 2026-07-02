# Phase 1 — VMs automatisées + cluster k3s en HA

Objectif : à partir d'un seul `vagrant up`, obtenir un cluster Kubernetes (k3s)
**hautement disponible** : 3 control planes avec etcd en quorum, une VIP portée par
kube-vip devant les API servers, et 3 workers.

C'est la contrainte **HA** du projet + la base sur laquelle tout le reste (GitOps,
observabilité, backup, autoscaling) viendra se greffer dans les phases suivantes.

---

## 1. Architecture cible

```
                        VIP 192.168.60.10  (kube-vip, ARP)
                                 │  :6443
        ┌────────────────────────┼────────────────────────┐
        │                        │                         │
   ┌─────────┐              ┌─────────┐               ┌─────────┐
   │  cp1    │  etcd  ◄────► │  cp2    │  etcd  ◄────►  │  cp3    │
   │ .11     │              │ .12     │               │ .13     │
   └─────────┘              └─────────┘               └─────────┘
        ▲                        ▲                         ▲
        └───────────── plan de données ───────────────────┘
   ┌─────────┐              ┌─────────┐               ┌─────────┐
   │  w1 .21 │              │  w2 .22 │               │  w3 .23 │
   └─────────┘              └─────────┘               └─────────┘
```

- **HA control plane** : etcd est répliqué sur 3 nœuds → quorum de 2, on peut perdre
  1 control plane sans perdre le cluster.
- **HA point d'entrée** : `kube-vip` fait flotter l'IP `.10` sur l'un des control planes
  vivants (élection de leader). Si ce nœud tombe, la VIP saute sur un autre. Pas de
  VM load-balancer séparée à maintenir.

### Budget RAM (hôte 32 Go)

| VMs            | Rôle                | RAM unit. | Total  |
|----------------|---------------------|-----------|--------|
| cp1, cp2, cp3  | k3s server + etcd   | 2 Go      | 6 Go   |
| w1, w2, w3     | k3s agent (workers) | 4 Go      | 12 Go  |
| **Total**      |                     |           | **18 Go** |

Il reste de la marge pour Windows + VMware. Le 2ᵉ cluster (bonus multicluster,
phase 6) ajoutera ~2 Go.

---

## 2. Prérequis sur l'hôte (Windows)

1. **VMware Workstation** installé (gratuit pour un usage personnel depuis fin 2024).
2. **Vagrant** (HashiCorp).
3. **Vagrant VMware Utility** — téléchargement séparé, à installer sur l'hôte.
   Voir la doc du provider : https://developer.hashicorp.com/vagrant/docs/providers/vmware
4. Le **plugin** provider VMware (désormais gratuit / open source, plus de licence) :

   ```powershell
   vagrant plugin install vagrant-vmware-desktop
   ```

### Réseau — point d'attention

Les VMs utilisent un réseau **hostonly** `192.168.60.0/24`. La VIP `.10` et les IP des
nœuds (`.11`–`.23`) doivent rester **hors de la plage DHCP** du vmnet VMware (par défaut
VMware distribue à partir de `.128`, donc pas de collision ici). Si tu as un doute,
vérifie dans *Virtual Network Editor* que le DHCP du vmnet hostonly ne recouvre pas
`.10`–`.23`.

---

## 3. Lancement

Depuis le dossier `k8s-platform/` :

```powershell
vagrant up
```

Ordre d'exécution (géré automatiquement par les scripts) :

1. **cp1** installe k3s en `--cluster-init` (crée l'etcd), puis déploie kube-vip →
   la VIP `.10` s'active.
2. **cp2** et **cp3** attendent que la VIP réponde, puis rejoignent en tant que servers.
3. **w1/w2/w3** attendent la VIP puis rejoignent en tant qu'agents.

À la fin, un fichier **`kubeconfig`** est déposé à la racine du projet (déjà pointé sur
la VIP). Sur l'hôte :

```powershell
$env:KUBECONFIG = "$PWD\kubeconfig"
kubectl get nodes -o wide
```

Résultat attendu : 6 nœuds `Ready`, dont 3 avec le rôle `control-plane,etcd,master`.

> Pas de `kubectl` sur l'hôte ? Tu peux aussi faire `vagrant ssh cp1` puis
> `sudo k3s kubectl get nodes`.

---

## 4. Comment ça marche (à savoir expliquer au prof)

- **k3s** : distribution Kubernetes légère, un seul binaire. `--cluster-init` sur le
  premier nœud active **etcd embarqué** ; les serveurs suivants le rejoignent avec le
  même `--token`.
- **`--tls-san <VIP>`** : ajoute la VIP aux certificats de l'API server, sinon les appels
  via `https://192.168.60.10:6443` seraient refusés (certificat invalide).
- **kube-vip en mode ARP** : un DaemonSet sur les control planes. Le leader répond aux
  requêtes ARP pour l'IP `.10` (ARP gratuit) → le réseau L2 route la VIP vers lui. En cas
  de panne, un autre réplica gagne l'élection et récupère la VIP.
- **Déploiement de kube-vip via `/var/lib/rancher/k3s/server/manifests/`** : k3s applique
  automatiquement tout YAML déposé dans ce dossier. Pratique pour bootstrapper sans
  `kubectl apply` manuel.

---

## 5. Démo HA (le moment qui prouve la contrainte)

```powershell
# 1. Repérer quel nœud porte actuellement la VIP
vagrant ssh cp1 -c "ip addr | grep 192.168.60.10"

# 2. Éteindre brutalement un control plane
vagrant halt cp1 -f

# 3. Depuis l'hôte, l'API répond toujours (la VIP a basculé, etcd garde le quorum)
kubectl get nodes
```

Attendu : `cp1` passe `NotReady`, **mais** `kubectl` continue de répondre et les workloads
restent schedulés. Rallumer ensuite :

```powershell
vagrant up cp1
```

> À ne PAS faire en démo : éteindre 2 control planes sur 3 en même temps → perte du
> quorum etcd, l'API devient read-only. C'est justement ce que le quorum protège, et un
> bon point à mentionner à l'oral.

---

## 6. Cycle de vie

```powershell
vagrant status            # état des 6 VMs
vagrant halt              # tout éteindre (garde les disques)
vagrant up                # rallumer
vagrant destroy -f        # tout supprimer (repartir de zéro)
vagrant ssh cp1           # se connecter à un nœud
```

---

## 7. Dépannage

| Symptôme | Piste |
|----------|-------|
| `vagrant up` ne détecte pas VMware | Le *Vagrant VMware Utility* n'est pas installé/lancé sur l'hôte. |
| cp2/cp3 bloqués sur « Attente de l'API » | kube-vip n'a pas pris la VIP sur cp1 : vérifier `sudo k3s kubectl -n kube-system get pods | grep kube-vip` et l'interface détectée. |
| Certificat invalide via la VIP | Un `--tls-san <VIP>` manque : re-provisionner (`vagrant provision`). |
| Pas de fichier `kubeconfig` sur l'hôte | Dossier synchronisé `/vagrant` KO (open-vm-tools) : récupérer via `vagrant ssh cp1 -c "sudo cat /etc/rancher/k3s/k3s.yaml"` et remplacer `127.0.0.1` par la VIP. |
| Collision d'IP / VIP injoignable | Plage DHCP du vmnet hostonly recouvre `.10`–`.23` : ajuster dans *Virtual Network Editor*. |

---

## 8. Ce qui arrive en phase 2

On installera **Argo CD** sur ce cluster, en pattern *app-of-apps* : à partir de là, tout
le reste (observabilité, backup, autoscaling) sera décrit dans Git et déployé
automatiquement. C'est le bonus « déploiement auto » qui devient la colonne vertébrale du
projet.
