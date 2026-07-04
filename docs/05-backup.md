# Phase 5 — Backup (Velero + MinIO + snapshots etcd)

Objectif : couvrir la contrainte **backup** avec une stratégie à **deux étages** :
- **Velero** : sauvegarde/restauration des ressources Kubernetes (et des données de
  volumes) vers un stockage S3 — ici **MinIO**, déployé dans le cluster ;
- **snapshots etcd** (intégrés à k3s) : le plan de secours du control plane lui-même.

Et bien sûr : tout est déployé en GitOps, y compris le **backup planifié** (cron).

---

## 1. Architecture

```
   ┌─────────────────────────────── cluster ───────────────────────────────┐
   │                                                                        │
   │  namespace demo ──backup──► VELERO ──écrit──► MinIO (bucket "velero") │
   │  (+ tout autre ns)             │                   │ PVC 10Gi          │
   │                            node-agent ×6          │                   │
   │                          (données des volumes)    │                   │
   │                                                                        │
   │  etcd (cp1/cp2/cp3) ──snapshots k3s──► /var/lib/rancher/k3s/.../snapshots
   └────────────────────────────────────────────────────────────────────────┘
```

### Pourquoi deux étages ? (à savoir expliquer)
- **Velero** répond à : « j'ai perdu/cassé une application, un namespace, des
  données » → restauration ciblée, granulaire.
- **Snapshots etcd** répondent à : « j'ai perdu le cluster lui-même » (quorum etcd
  détruit, corruption) → restauration du cerveau complet du cluster.
Un backup applicatif ne sert à rien si le cluster est mort ; un snapshot etcd ne
restaure pas les données des volumes. Les deux sont complémentaires.

### Velero vs GitOps — la question piège
« Pourquoi un backup si tout est dans Git ? » Réponse : Git ne contient que le
**déclaratif**. Velero couvre ce que Git ne voit pas :
- l'**état runtime** : Secrets créés à la volée, ressources créées hors Git, PVC ;
- les **données** dans les volumes (Grafana, Loki, MinIO... : Git n'a pas tes
  dashboards personnalisés ni tes métriques) ;
- le **disaster recovery rapide** : restaurer un namespace entier en une commande,
  sans attendre la reconvergence de tout le GitOps.
Git = la recette. Velero = la photo du plat. Les deux se complètent.

---

## 2. Ce qui est déployé

| Fichier | Contenu |
|---|---|
| `manifests/minio/` | MinIO (Deployment + Service + PVC 10 Gi) + Job de création du bucket `velero` |
| `apps/minio.yaml` | Application Argo de MinIO (ns `minio`) |
| `apps/velero.yaml` | Velero via chart Helm 12.1.0 (ns `velero`) : plugin S3, credentials MinIO, node-agent, **backup planifié quotidien** du ns `demo` (3h00, rétention 72h) |

Points de configuration à connaître :
- **`s3ForcePathStyle: "true"`** : obligatoire avec MinIO (adressage par chemin,
  pas par sous-domaine comme AWS).
- **`defaultVolumesToFsBackup: true`** + **node-agent** : les données des volumes
  sont sauvegardées par copie de fichiers (kopia) — la seule méthode possible en
  local, où il n'existe pas d'API de snapshot de disque comme chez un cloud provider.
- **`snapshotsEnabled: false`** : cohérent avec le point précédent.
- **Image MinIO épinglée `RELEASE.2025-07-23`** : MinIO ne publie plus d'images
  officielles depuis fin 2025 (projet en lecture seule) ; cette release reste la
  dernière disponible sur Docker Hub — suffisant et stable pour un lab.
- **`schedules.daily-demo`** : la contrainte backup en mode *automatique*, versionnée
  dans Git comme le reste.

Déploiement :
```powershell
git add .
git commit -m "Phase 5 : backup Velero + MinIO"
git push
```

Vérifications après convergence (~3-5 min) :
```powershell
kubectl get applications -n argocd            # minio + velero Synced/Healthy
kubectl get pods -n minio                     # minio Running, job Completed
kubectl get pods -n velero                    # velero + node-agent ×6
kubectl get backupstoragelocation -n velero   # default -> PHASE: Available  <- LE test
kubectl get schedule -n velero                # daily-demo
```
`BackupStorageLocation` en **Available** = Velero parle à MinIO. C'est le feu vert.

---

## 3. LA démo : suppression « accidentelle » + restauration

> On utilise un namespace de test **non géré par Argo** : si on supprimait `demo`,
> Argo le recréerait immédiatement (selfHeal) — ce qui est une super démo GitOps,
> mais brouillerait la démo backup. Sur un namespace hors Git, seul Velero peut
> le faire revenir : la démonstration est sans ambiguïté.

### 1. Créer des données « précieuses »
```powershell
kubectl create namespace donnees-critiques
kubectl create configmap rapport-final -n donnees-critiques --from-literal=contenu="6 mois de travail irremplacable"
kubectl create secret generic mdp-prod -n donnees-critiques --from-literal=password="tres-secret"
```

### 2. Sauvegarder (un Backup à la demande, via un CR — pas besoin du CLI velero)
```powershell
@"
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: sauvegarde-critique
  namespace: velero
spec:
  includedNamespaces:
    - donnees-critiques
  ttl: 72h0m0s
"@ | kubectl apply -f -

# suivre jusqu'a PHASE: Completed
kubectl get backup -n velero -w
```

### 3. La catastrophe
```powershell
kubectl delete namespace donnees-critiques
kubectl get configmap -n donnees-critiques    # Error : plus rien n'existe
```

### 4. La restauration
```powershell
@"
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: restauration-critique
  namespace: velero
spec:
  backupName: sauvegarde-critique
"@ | kubectl apply -f -

kubectl get restore -n velero -w              # attendre PHASE: Completed
```

### 5. La preuve
```powershell
kubectl get configmap rapport-final -n donnees-critiques -o jsonpath="{.data.contenu}"
# -> "6 mois de travail irremplacable"
kubectl get secret mdp-prod -n donnees-critiques    # revenu aussi
```

Namespace, ConfigMap, Secret : tout est revenu depuis MinIO. Contrainte démontrée.

### Bonus visuel : la console MinIO
```powershell
kubectl -n minio port-forward svc/minio 9001:9001
```
→ http://localhost:9001 (minioadmin / minioadmin-lab) → bucket `velero` → on voit
physiquement les fichiers de backup. Très parlant en soutenance.

---

## 4. L'étage 2 : snapshots etcd (k3s)

k3s fait des snapshots etcd **automatiquement** (toutes les 12 h, rétention 5) sur
chaque nœud serveur. Pour le montrer / en déclencher un :

```powershell
vagrant ssh cp1 -c "sudo k3s etcd-snapshot save --name demo-soutenance"
vagrant ssh cp1 -c "sudo k3s etcd-snapshot ls"
```

Les snapshots vivent dans `/var/lib/rancher/k3s/server/db/snapshots/`. La restauration
complète (`k3s server --cluster-reset --cluster-reset-restore-path=...`) est
documentée par k3s ; à **mentionner** en soutenance, mais ne la testez pas sur le
cluster de démo (elle réinitialise le control plane).

---

## 5. Dépannage

| Symptôme | Piste |
|---|---|
| BSL `Unavailable` | MinIO pas prêt ou bucket absent : vérifier le Job `minio-create-bucket` (Completed ?) et l'URL s3. |
| Backup `PartiallyFailed` | Souvent les volumes : voir `kubectl logs -n velero deploy/velero`. Pour la démo (ConfigMap/Secret), aucun volume en jeu. |
| Job bucket en erreur | MinIO a mis du temps à démarrer : le Job réessaie tout seul (backoffLimit 6). |
| App velero SyncFailed sur CRDs | `ServerSideApply=true` (déjà dans notre fichier). |
| Restore ne recrée rien | Le namespace existait encore ? Velero ne remplace pas les ressources existantes par défaut. Supprimer puis restaurer. |

---

## 6. État du projet

| Contrainte | État |
|---|---|
| HA | ✅ Phase 1 |
| Déploiement auto 🎁 | ✅ Phase 2 |
| Observabilité | ✅ Phase 3 |
| Autoscaling | ✅ Phase 4 |
| **Backup** | ✅ **Phase 5** |
| Multicluster 🎁 | ⬜ Phase 6 — dernière ligne droite |

Phase 6 : un **2ᵉ cluster k3s** (VM légère) piloté par le même Argo CD via un
**ApplicationSet** — le bonus multicluster, et la fin du projet.
