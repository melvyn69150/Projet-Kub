# Phase 3 — Observabilité (Prometheus, Grafana, Alertmanager, Loki, Alloy)

Objectif : couvrir la contrainte **observabilité** avec les deux piliers principaux —
**métriques** (Prometheus + Grafana + Alertmanager) et **logs** (Loki + Alloy) —
déployés **entièrement en GitOps** : deux fichiers dans `apps/`, un `git push`, et
Argo CD installe tout.

---

## 1. Architecture

```
                          ┌────────── GRAFANA ──────────┐
                          │   (dashboards, exploration)  │
                          └───────┬──────────────┬───────┘
                        requêtes  │              │  requêtes
                                  ▼              ▼
                     ┌─────────────────┐   ┌──────────┐
   alertes ◄─────────│   PROMETHEUS    │   │   LOKI   │
 (Alertmanager)      │   (métriques)   │   │  (logs)  │
                     └────────▲────────┘   └────▲─────┘
                       scrape │                 │ push
              ┌───────────────┴───┐      ┌─────┴──────┐
              │ node-exporter (×6)│      │ ALLOY (×6) │
              │ kube-state-metrics│      │ DaemonSet  │
              │ podinfo /metrics  │      │ lit les    │
              │ ...               │      │ logs pods  │
              └───────────────────┘      └────────────┘
```

Deux logiques opposées, à savoir expliquer :
- **Métriques = PULL** : Prometheus va *chercher* (`scrape`) les métriques sur les
  cibles toutes les 15-30 s.
- **Logs = PUSH** : Alloy (un pod par nœud) lit les logs de tous les conteneurs du
  nœud et les *pousse* vers Loki.

Grafana ne stocke rien : il interroge Prometheus et Loki à la volée.

### Pourquoi Alloy et pas Promtail ?
Promtail (l'ancien collecteur Loki) est **EOL depuis le 2 mars 2026** — plus de
mises à jour ni de correctifs de sécurité. Grafana l'a remplacé par **Alloy**, son
collecteur unifié basé sur OpenTelemetry. Utiliser Alloy, c'est être à jour de
l'état de l'art (bon point en soutenance).

---

## 2. Ce qui est déployé (les fichiers)

| Fichier | Contenu |
|---|---|
| `apps/kube-prometheus-stack.yaml` | Prometheus Operator + Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics (chart Helm 87.4.0, ns `monitoring`) |
| `apps/logging.yaml` | Loki 18.3.0 (mode Monolithic, ns `logging`) + Alloy 1.9.0 (DaemonSet) |
| `manifests/demo-podinfo/servicemonitor.yaml` | Dit à Prometheus de scraper `/metrics` de podinfo |
| `manifests/demo-podinfo/alert.yaml` | Alerte custom : « moins de 2 podinfo up pendant 2 min » |

### Choix de configuration importants (à connaître)

- **`ServerSideApply=true`** (kps) : les CRDs de Prometheus Operator sont trop
  grosses pour un apply classique ; sans cette option, la sync Argo échoue.
- **`kubeEtcd/kubeScheduler/kubeControllerManager/kubeProxy: enabled: false`** :
  dans k3s, ces composants sont *dans* le binaire k3s, pas dans des pods → les
  scraper est impossible et générerait des alertes `TargetDown` en permanence.
- **`serviceMonitorSelectorNilUsesHelmValues: false`** : par défaut Prometheus
  n'écoute que les ServiceMonitors du chart ; ce réglage lui fait découvrir
  **tous** les ServiceMonitors du cluster, dont celui de podinfo.
- **`chunksCache/resultsCache: enabled: false`** (Loki) : le chart déploie sinon
  des memcached qui réservent ~1 Gi de RAM — inutile en lab.
- **Toleration control-plane sur Alloy** : nos cp sont taintés ; sans toleration,
  aucun log des control planes ne serait collecté.
- **Rétention courte** (2 j de métriques, 48 h de logs) : adapté au lab.

---

## 3. Déploiement (pur GitOps)

```powershell
git add .
git commit -m "Phase 3 : observabilite (kps + loki + alloy)"
git push
```

C'est tout. L'app `root` détecte les nouveaux fichiers dans `apps/` (≤ 3 min) et crée
les applications `kube-prometheus-stack`, `loki` et `alloy`, qui installent leurs
charts. **Compter 5-10 min** (téléchargement des images). Suivre :

```powershell
kubectl get applications -n argocd
kubectl get pods -n monitoring
kubectl get pods -n logging
```

> Note : `demo-podinfo` peut passer brièvement en erreur le temps que les CRDs de
> Prometheus Operator existent (le ServiceMonitor en dépend). La `retry` policy
> d'Argo résout ça tout seul en une ou deux minutes.

---

## 4. Accéder à Grafana

```powershell
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Navigateur → **http://localhost:3000** — login `admin` / `admin-lab`.

À explorer :
- **Dashboards → dossier "Kubernetes"** : dizaines de dashboards préconfigurés
  (compute par namespace, par pod, réseau, API server...).
- **Node Exporter / Nodes** : CPU/RAM/disque de tes 6 VMs.
- **Explore → datasource Prometheus** : tester une requête PromQL, ex.
  `sum(up{job="podinfo"})` → doit retourner `3`.
- **Explore → datasource Loki** : requête LogQL, ex. `{namespace="demo"}` →
  les logs de tes podinfo en direct.

Alertmanager :
```powershell
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```
→ http://localhost:9093 (les alertes actives, dont quelques Watchdog normales).

---

## 5. Démos pour la soutenance

### Démo 1 — métriques applicatives
Dans Grafana Explore (Prometheus) : `rate(http_requests_total{namespace="demo"}[1m])`
puis génère du trafic (port-forward podinfo + rafraîchir la page) → la courbe monte.

### Démo 2 — logs centralisés
Explore (Loki) : `{namespace="demo"} |= "GET"` → les requêtes HTTP des 3 pods,
centralisées, filtrables. Tuer un pod et voir les logs du remplaçant arriver.

### Démo 3 — l'alerte custom (la boucle complète)
1. Casse volontairement la HA : `kubectl scale deploy/podinfo -n demo --replicas=1`
   … sauf qu'Argo (selfHeal) va le remettre à 3 ! **Deux options** :
   - montrer précisément ça (l'alerte n'a pas le temps de partir car l'auto-réparation
     est plus rapide — très bon storytelling GitOps), ou
   - suspendre l'auto-sync de `demo-podinfo` dans l'UI Argo le temps de la démo.
2. Avec l'auto-sync suspendu : scale à 1, attendre 2 min → l'alerte
   **PodinfoInsuffisant** passe en *Firing* dans Alertmanager.
3. Re-scale à 3 (ou réactive l'auto-sync) → l'alerte se résout.

---

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| App kps en SyncFailed « annotation too long » | L'option `ServerSideApply=true` manque (elle est dans notre fichier). |
| Pods Prometheus/Grafana `Pending` | RAM insuffisante sur les workers : `kubectl describe pod` → regarder les events ; vérifier qu'aucun autre gros workload ne tourne. |
| Cible podinfo absente dans Prometheus (Status→Targets) | ServiceMonitor pas pris en compte : vérifier `serviceMonitorSelectorNilUsesHelmValues: false` et le label `app: podinfo`. |
| Pas de logs dans Loki | `kubectl logs -n logging ds/alloy` → erreurs de push ? Vérifier l'URL `loki.logging.svc...:3100`. |
| Datasource Loki en erreur dans Grafana | Loki pas encore prêt (il démarre en ~1 min) ; re-tester. |

---

## 7. Ce qui arrive en phase 4

L'**autoscaling** : un HPA sur podinfo (CPU) + KEDA pour l'event-driven. Et cerise :
on **verra l'autoscaling se déclencher en direct dans Grafana** — les métriques de la
phase 3 serviront de preuve visuelle à la phase 4.
