# Phase 4 — Autoscaling (HPA + KEDA)

Objectif : couvrir la contrainte **autoscaling** avec deux mécanismes complémentaires :
- le **HPA** classique (Horizontal Pod Autoscaler) : scale podinfo selon le **CPU** ;
- **KEDA** (CNCF graduated) : scaling **événementiel** piloté par une métrique
  **Prometheus** (le trafic HTTP de podinfo), avec **scale-to-zero** — ce que le HPA
  seul ne sait pas faire.

Bonus de cohérence : KEDA s'appuie sur le Prometheus de la phase 3, et Grafana sert
d'écran de contrôle pour *voir* le scaling en direct.

---

## 1. Les deux mécanismes

### HPA (podinfo)
```
metrics-server ──(CPU des pods)──► HPA ──(ajuste replicas)──► Deployment podinfo
```
Le HPA compare le CPU consommé aux `resources.requests` du pod (50m). Cible : 70 %.
Si la moyenne dépasse 35m/pod → il ajoute des pods (max 6). Si elle retombe → il en
retire (min 3, cohérent avec notre HA : spread sur 3 workers + PDB `minAvailable: 2`).
Le `metrics-server` est **intégré à k3s**, rien à installer.

### KEDA (podinfo-worker)
```
Prometheus ──(req/s sur podinfo)──► KEDA ──(crée/ajuste un HPA)──► podinfo-worker
```
KEDA interroge Prometheus toutes les 15 s : `rate` des requêtes HTTP reçues par
podinfo. Au-delà de **5 req/s par worker**, il crée des `podinfo-worker` (max 4).
Trafic nul pendant 60 s → retour à **0 pod**. KEDA ne remplace pas le HPA : il en
crée un sous le capot et lui fournit des métriques externes.

### HPA vs KEDA — à savoir dire
| | HPA | KEDA |
|---|---|---|
| Déclencheur | CPU/RAM des pods | N'importe quel événement (Prometheus, files, cron, ~70 scalers) |
| Scale-to-zero | ❌ (min 1) | ✅ (min 0) |
| Cas d'usage | Charge « continue » (web) | Charge « par vagues » (workers, jobs, files) |

---

## 2. Le piège HPA + GitOps (et sa solution)

Si `replicas: 3` reste dans Git, Argo (selfHeal) **remet 3** à chaque fois que le HPA
scale → bagarre sans fin. Solution appliquée (bonne pratique officielle) :
1. le champ `replicas` est **retiré** du deployment dans Git — le HPA en devient le
   seul propriétaire ;
2. les Applications Argo ont `ignoreDifferences` sur `/spec/replicas` +
   `RespectIgnoreDifferences=true` (ceinture et bretelles).

> Effet transitoire au premier sync : les replicas peuvent brièvement retomber à 1
> avant que le HPA ne remonte à `minReplicas: 3` (quelques secondes). Normal.

---

## 3. Fichiers de la phase

| Fichier | Rôle |
|---|---|
| `manifests/demo-podinfo/hpa.yaml` | HPA CPU 70 %, min 3 / max 6, sur podinfo |
| `manifests/demo-podinfo/deployment.yaml` | *(modifié)* champ `replicas` retiré |
| `apps/demo-podinfo.yaml` | *(modifié)* ignoreDifferences sur replicas |
| `apps/keda.yaml` | KEDA 2.20.1 (chart officiel, ns `keda`) |
| `manifests/keda-worker/deployment.yaml` | Le worker de démo (0 pod au repos) |
| `manifests/keda-worker/scaledobject.yaml` | La règle KEDA (trigger Prometheus) |
| `apps/keda-worker.yaml` | Application Argo du worker |

Déploiement — tu connais la musique :
```powershell
git add .
git commit -m "Phase 4 : autoscaling HPA + KEDA"
git push
```

Vérifications après convergence :
```powershell
kubectl get applications -n argocd          # keda + keda-worker en Synced/Healthy
kubectl get hpa -n demo                     # podinfo (HPA) + keda-hpa-podinfo-worker
kubectl get scaledobject -n demo            # podinfo-worker, READY True
kubectl get pods -n demo                    # 3 podinfo... et 0 podinfo-worker (normal !)
```

---

## 4. LA démo de charge (le moment fort de la soutenance)

### Préparer les écrans
- Terminal 1 : `kubectl get hpa -n demo -w`
- Terminal 2 : `kubectl get pods -n demo -w`
- (Optionnel) Grafana ouvert sur le dashboard *Kubernetes / Compute Resources /
  Namespace (Pods)*, namespace `demo`.

### Générer la charge
```powershell
# 3 generateurs de trafic en parallele (dans le cluster)
kubectl run -n demo load1 --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://podinfo:9898/ > /dev/null; done"
kubectl run -n demo load2 --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://podinfo:9898/ > /dev/null; done"
kubectl run -n demo load3 --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://podinfo:9898/ > /dev/null; done"
```

### Ce qui se passe (2-3 minutes)
1. Le CPU des podinfo grimpe au-dessus de 70 % des requests → **le HPA passe de 3 à
   4, 5, 6 pods** (terminal 1 : colonne TARGETS, puis REPLICAS).
2. Le débit dépasse le seuil KEDA → **des `podinfo-worker` apparaissent de 0 → 1 →
   2...** (terminal 2). Le scale-from-zero, en direct.

### Arrêter la charge
```powershell
kubectl delete pod -n demo load1 load2 load3
```
3. Le CPU retombe → le HPA redescend vers 3 (fenêtre de stabilisation 60 s,
   la descente prend ~1-5 min : c'est voulu, anti yo-yo).
4. Après 60 s de calme → **les workers repartent à 0**.

---

## 5. Dépannage

| Symptôme | Piste |
|---|---|
| HPA affiche `<unknown>/70%` | metrics-server pas prêt ou requests absentes du deployment ; `kubectl top pods -n demo` doit répondre. |
| ScaledObject `READY: False` | `kubectl describe scaledobject -n demo podinfo-worker` → souvent l'URL Prometheus ou la requête PromQL ; tester la query dans Grafana Explore. |
| Workers ne montent jamais | Le seuil (5 req/s) n'est pas atteint : ajouter des générateurs de charge, ou vérifier la métrique `http_request_duration_seconds_count` dans Prometheus. |
| Replicas podinfo « bloqués » à 1 au premier sync | Transitoire (voir §2) ; le HPA remonte à 3 en <1 min. |
| App keda en SyncFailed sur les CRDs | `ServerSideApply=true` manquant (présent dans notre fichier). |

---

## 6. Ce qui arrive en phase 5

Le **backup** : Velero + MinIO (stockage S3 in-cluster) + les snapshots etcd de k3s.
Démo : suppression « accidentelle » du namespace `demo`... et restauration complète.
