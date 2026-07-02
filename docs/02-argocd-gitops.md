# Phase 2 — GitOps avec Argo CD (déploiement auto)

Objectif : installer **Argo CD** et mettre en place le pattern **app-of-apps**, pour
que tout le reste de la plateforme (observabilité, backup, autoscaling) se déploie
**automatiquement depuis Git**. C'est le bonus « déploiement auto », et surtout la
colonne vertébrale de tout le projet à partir d'ici.

---

## 1. Le principe du GitOps (à savoir expliquer)

Avec le GitOps, **le dépôt Git est la seule source de vérité**. Tu ne fais plus de
`kubectl apply` à la main : tu décris l'état voulu du cluster dans Git, et un agent
(Argo CD) qui tourne *dans* le cluster compare en continu l'état réel à l'état décrit
dans Git, puis corrige tout écart.

```
   Toi ──push──> GitHub ──surveille──> Argo CD (dans le cluster) ──applique──> Kubernetes
                                            ▲                                      │
                                            └──────── compare en boucle ───────────┘
```

Conséquences concrètes :
- **Traçabilité** : tout changement est un commit (qui, quoi, quand).
- **Auto-réparation** (`selfHeal`) : si quelqu'un modifie une ressource à la main, Argo
  la remet conforme à Git.
- **Reproductible** : le prof clone le repo, pointe Argo dessus, et obtient le même état.

### Pattern app-of-apps

Une **Application racine** (`root`) surveille le dossier `apps/` du repo. Chaque fichier
qu'on y dépose est lui-même une **Application** Argo CD qui déploie un composant. Résultat :
pour ajouter l'observabilité en phase 3, on ajoutera juste un `apps/observability.yaml` et
un `git push` — Argo fait le reste.

```
bootstrap/root-app.yaml   ──> surveille apps/
apps/demo-podinfo.yaml    ──> déploie manifests/demo-podinfo/
apps/observability.yaml   ──> (phase 3)
apps/backup.yaml          ──> (phase 5)
```

---

## 2. Prérequis : pousser le repo sur GitHub

**Argo CD tire depuis un dépôt Git distant, pas depuis ton dossier local.** Il faut donc
un dépôt GitHub. Un repo **public** évite toute gestion de credentials (tes VMs ont accès
internet via le NAT).

1. Crée un repo `k8s-platform` sur GitHub (public).
2. Depuis `C:\dev\k8s-plateform` :
   ```powershell
   git init
   git add .
   git commit -m "Phase 1 + 2 : k3s HA + Argo CD"
   git branch -M main
   git remote add origin https://github.com/<TON-USER>/k8s-platform.git
   git push -u origin main
   ```

3. **Remplace l'URL `repoURL`** par la tienne dans **deux** fichiers :
   - `bootstrap/root-app.yaml`
   - `apps/demo-podinfo.yaml`

   (cherche `CHANGE-ME`). Puis commit + push à nouveau.

> `.gitignore` : ajoute `kubeconfig` et `.vagrant/` pour ne pas les pousser.

---

## 3. Installer Argo CD (bootstrap)

Depuis l'hôte, avec le kubeconfig déjà configuré (`$env:KUBECONFIG`) :

```powershell
# 1. Namespace + installation d'Argo CD (version epinglee)
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts `
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.4/manifests/install.yaml

# 2. Attendre que le serveur Argo soit pret
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# 3. Appliquer l'app racine (app-of-apps)
kubectl apply -f bootstrap/root-app.yaml
```

> `--server-side --force-conflicts` est requis : les CRD d'Argo CD sont trop grosses pour
> l'apply classique.
> Si l'URL en `v3.4.4` renvoie une erreur, remplace par `stable`.

À partir de là, Argo lit `apps/`, y trouve `demo-podinfo`, et déploie podinfo tout seul.

---

## 4. Accéder à l'interface Argo CD

```powershell
# Mot de passe admin initial (PowerShell)
$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))

# Ouvrir l'UI (laisse cette fenetre ouverte)
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Navigateur → **https://localhost:8080** (certificat auto-signé, on accepte). Login `admin`
+ le mot de passe ci-dessus. Tu verras l'app `root` et l'app `demo-podinfo` passer en
**Synced / Healthy** — c'est la preuve visuelle à montrer au prof.

---

## 5. Vérifications

```powershell
kubectl get applications -n argocd          # root + demo-podinfo : Synced/Healthy
kubectl get pods -n demo -o wide            # 3 podinfo, sur 3 noeuds differents
kubectl get pdb -n demo                     # podinfo : minAvailable 2
```

Test applicatif rapide :
```powershell
kubectl -n demo port-forward svc/podinfo 9898:9898
# navigateur -> http://localhost:9898
```

---

## 6. La démo GitOps (le moment « waouh »)

Prouve la boucle complète en direct :

1. Édite `manifests/demo-podinfo/deployment.yaml`, passe `replicas: 3` à `5`.
2. `git commit -am "scale podinfo a 5" && git push`
3. Sans rien faire d'autre, regarde l'UI Argo (ou `kubectl get pods -n demo -w`) :
   Argo détecte le changement et crée 2 pods de plus, **tout seul**.

Autre démo (auto-réparation) : supprime un pod à la main
(`kubectl delete pod -n demo <nom>`). Kubernetes le recrée (ReplicaSet), et Argo confirme
la conformité. Puis tente de changer les replicas à la main
(`kubectl scale deploy/podinfo -n demo --replicas=1`) : `selfHeal` le remet à la valeur
de Git en quelques secondes.

---

## 7. Dépannage

| Symptôme | Piste |
|----------|-------|
| App `root` en `Unknown` / erreur repo | `repoURL` faux ou repo privé : vérifier l'URL, rendre le repo public. |
| App reste `OutOfSync` | Regarder les détails dans l'UI Argo (onglet de l'app) ; souvent un chemin `path` incorrect. |
| `demo-podinfo` absente | L'app `root` pointe-t-elle bien sur `path: apps` ? As-tu poussé `apps/demo-podinfo.yaml` ? |
| Pods podinfo `Pending` | `topologySpreadConstraints` + peu de nœuds : normal si tu as moins de nœuds que de replicas. |
| Port-forward coupe | Il occupe le terminal ; ouvre une 2ᵉ fenêtre PowerShell pour les autres commandes. |

---

## 8. Ce qui arrive en phase 3

On ajoutera `apps/observability.yaml` : Argo installera **kube-prometheus-stack**
(Prometheus + Grafana + Alertmanager) et **Loki** pour les logs — entièrement en GitOps.
Tu ne feras qu'un `git push`.
