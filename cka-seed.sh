#!/usr/bin/env bash
# =============================================================================
# cka-seed.sh - Peuple le lab CKA avec une charge realiste, alignee sur le programme CKA.
# A lancer sur cka-cp1, en tant qu'ubuntu (kubectl + helm deja configures).
# Idempotent : relancable sans casse (kubectl apply / helm upgrade --install).
#
# Ajoute :
#   Add-ons     : StorageClass par defaut (local-path), metrics-server,
#                 Traefik (IngressClass + GatewayClass/Gateway, CRDs Gateway API), Helm repos
#   Workloads   : 6 namespaces "entreprise" (frontend, backend, data, monitoring, batch, team-a)
#                 Deployment, StatefulSet, DaemonSet, Job, CronJob, init/sidecar containers,
#                 HPA, PDB, PriorityClass, topologySpread, nodeSelector
#   Reseau      : Services, Ingress, HTTPRoute cross-namespace + ReferenceGrant, NetworkPolicies
#   Stockage    : PVC dynamiques, StorageClass manuelle + PV statiques
#   Securite    : ServiceAccounts, Roles/ClusterRoles, bindings, ResourceQuota, LimitRange
#   Extension   : CRD maison + custom resources ; materiel Kustomize (non applique)
# Les manifests sont ecrits dans ~/manifests/seed pour pouvoir les relire/modifier.
# =============================================================================
set -euo pipefail

LOCAL_PATH_VERSION="v0.0.37"
METRICS_SERVER_VERSION="v0.9.0"
TRAEFIK_CHART_VERSION="41.6.0"
PODINFO_CHART_VERSION="6.15.0"
GATEWAY_API_VERSION="v1.6.1"    # version indiquee par la doc Traefik v3.7 (chart 41.6.0 = Traefik v3.7.13)

SEED_DIR="${HOME}/manifests/seed"
KUSTOMIZE_DIR="${HOME}/manifests/kustomize"
mkdir -p "${SEED_DIR}" "${KUSTOMIZE_DIR}"

log()  { printf '\n\033[1;34m[seed]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
apply_file() { kubectl apply -f "$1" >/dev/null && echo "  applique : $(basename "$1")"; }

# ----------------------------------------------------------------- prerequis
log "Verification des prerequis"
command -v kubectl >/dev/null || { echo "kubectl introuvable"; exit 1; }
command -v helm    >/dev/null || { echo "helm introuvable (sudo snap install helm --classic)"; exit 1; }
kubectl get nodes >/dev/null || { echo "kubectl ne joint pas le cluster"; exit 1; }

mapfile -t WORKERS < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
[ "${#WORKERS[@]}" -ge 2 ] || { echo "Il faut au moins 2 workers (trouve : ${#WORKERS[@]})"; exit 1; }
W1="${WORKERS[0]}"; W2="${WORKERS[1]}"
echo "  workers : ${W1}, ${W2}"

# ----------------------------------------------------------------- noeuds
log "Labels des noeuds (zones / type de disque)"
kubectl label node "${W1}" topology.kubernetes.io/zone=zone-a disk=ssd --overwrite >/dev/null
kubectl label node "${W2}" topology.kubernetes.io/zone=zone-b disk=hdd --overwrite >/dev/null

# ----------------------------------------------------------------- add-ons
log "StorageClass dynamique : local-path-provisioner ${LOCAL_PATH_VERSION} (classe par defaut)"
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" >/dev/null
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=300s

log "metrics-server ${METRICS_SERVER_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" >/dev/null
# kubeadm : certificats kubelet auto-signes -> --kubelet-insecure-tls (acceptable en lab uniquement)
if ! kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
  kubectl -n kube-system patch deploy metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
fi
kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s

log "Helm : depots"
helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
helm repo add podinfo https://stefanprodan.github.io/podinfo --force-update >/dev/null
helm repo update >/dev/null

log "CRDs Gateway API ${GATEWAY_API_VERSION} (canal standard) : le chart Traefik ne les fournit pas"
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io --timeout=120s >/dev/null

log "Traefik ${TRAEFIK_CHART_VERSION} : IngressClass + Gateway API (NodePort 30080/30443)"
# Une premiere installation echouee bloque 'helm upgrade --install' : on la retire avant de reessayer
if helm status traefik -n traefik 2>/dev/null | grep -qiE 'STATUS: (failed|pending)'; then
  warn "Release traefik en echec detectee : desinstallation avant nouvel essai"
  helm uninstall traefik -n traefik --wait >/dev/null || true
fi
helm upgrade --install traefik traefik/traefik --version "${TRAEFIK_CHART_VERSION}" \
  --namespace traefik --create-namespace \
  --set providers.kubernetesGateway.enabled=true \
  --set gateway.name=traefik-gateway \
  --set gateway.listeners.web.namespacePolicy.from=All \
  --set service.spec.type=NodePort \
  --set ports.web.nodePort=30080 \
  --set ports.websecure.nodePort=30443 \
  --wait --timeout 5m >/dev/null
kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=120s >/dev/null
kubectl wait --for=condition=Established crd/referencegrants.gateway.networking.k8s.io --timeout=120s >/dev/null

# ----------------------------------------------------------------- base : namespaces, priorite, stockage, CRD
log "Namespaces, PriorityClass, stockage manuel, CRD"
cat > "${SEED_DIR}/00-base.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata: { name: frontend, labels: { team: web, env: prod } }
---
apiVersion: v1
kind: Namespace
metadata: { name: backend, labels: { team: api, env: prod } }
---
apiVersion: v1
kind: Namespace
metadata: { name: data, labels: { team: dba, env: prod } }
---
apiVersion: v1
kind: Namespace
metadata: { name: monitoring, labels: { team: ops } }
---
apiVersion: v1
kind: Namespace
metadata: { name: batch, labels: { team: data-eng, env: prod } }
---
apiVersion: v1
kind: Namespace
metadata: { name: team-a, labels: { team: team-a, env: dev } }
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: business-critical
value: 100000
globalDefault: false
description: "Workloads metier critiques"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: manual
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-archive-01
  labels: { tier: archive }
spec:
  capacity: { storage: 1Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath: { path: /srv/archive-01, type: DirectoryOrCreate }
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-archive-02
  labels: { tier: archive }
spec:
  capacity: { storage: 2Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath: { path: /srv/archive-02, type: DirectoryOrCreate }
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.ops.example.com
spec:
  group: ops.example.com
  scope: Namespaced
  names:
    plural: backups
    singular: backup
    kind: Backup
    shortNames: [bk]
  versions:
    - name: v1
      served: true
      storage: true
      additionalPrinterColumns:
        - { name: Schedule,  type: string,  jsonPath: .spec.schedule }
        - { name: Target,    type: string,  jsonPath: .spec.target }
        - { name: Retention, type: integer, jsonPath: .spec.retentionDays }
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [schedule, target]
              properties:
                schedule:      { type: string }
                target:        { type: string }
                retentionDays: { type: integer, minimum: 1, default: 7 }
EOF
apply_file "${SEED_DIR}/00-base.yaml"
kubectl wait --for=condition=Established crd/backups.ops.example.com --timeout=60s >/dev/null

# ----------------------------------------------------------------- frontend
log "Namespace frontend : web (nginx), HPA, PDB, Ingress, HTTPRoute"
cat > "${SEED_DIR}/10-frontend.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: { name: web-content, namespace: frontend }
data:
  index.html: |
    <html><body><h1>Shop - frontend</h1></body></html>
  default.conf: |
    server {
      listen 80;
      location = /healthz { return 200 "ok\n"; }
      location / { root /usr/share/nginx/html; index index.html; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: frontend
  labels: { app: web, app.kubernetes.io/part-of: shop }
spec:
  replicas: 3
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web, tier: frontend } }
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app: web } }
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{ containerPort: 80, name: http }]
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 200m, memory: 64Mi }
          readinessProbe: { httpGet: { path: /healthz, port: http }, periodSeconds: 5 }
          livenessProbe:  { httpGet: { path: /healthz, port: http }, initialDelaySeconds: 10, periodSeconds: 10 }
          volumeMounts:
            - { name: content, mountPath: /usr/share/nginx/html/index.html, subPath: index.html }
            - { name: content, mountPath: /etc/nginx/conf.d/default.conf, subPath: default.conf }
      volumes:
        - name: content
          configMap: { name: web-content }
---
apiVersion: v1
kind: Service
metadata: { name: web, namespace: frontend, labels: { app: web } }
spec:
  selector: { app: web }
  ports: [{ name: http, port: 80, targetPort: http }]
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: web, namespace: frontend }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: web }
  minReplicas: 3
  maxReplicas: 6
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: web, namespace: frontend }
spec:
  minAvailable: 2
  selector: { matchLabels: { app: web } }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: web-legacy, namespace: frontend }
spec:
  ingressClassName: traefik
  rules:
    - host: legacy.shop.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: web, port: { number: 80 } } }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: shop, namespace: frontend }
spec:
  parentRefs:
    - { name: traefik-gateway, namespace: traefik, sectionName: web }
  hostnames: [shop.local]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /api } }]
      backendRefs: [{ name: api, namespace: backend, port: 9898 }]
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: web, port: 80 }]
EOF
apply_file "${SEED_DIR}/10-frontend.yaml"

# ----------------------------------------------------------------- backend
log "Namespace backend : api (Helm podinfo), redis, worker (init container, PriorityClass)"
helm upgrade --install api podinfo/podinfo --version "${PODINFO_CHART_VERSION}" \
  --namespace backend \
  --set fullnameOverride=api \
  --set replicaCount=2 \
  --wait --timeout 5m >/dev/null
kubectl -n backend get svc api >/dev/null 2>&1 || warn "Service 'api' introuvable dans backend : verifie le nom genere par le chart (kubectl -n backend get svc)"

cat > "${SEED_DIR}/20-backend.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: { name: app-config, namespace: backend }
data:
  REDIS_HOST: redis.backend.svc.cluster.local
  DB_HOST: postgres.data.svc.cluster.local
  LOG_LEVEL: info
---
apiVersion: v1
kind: Secret
metadata: { name: app-secret, namespace: backend }
type: Opaque
stringData:
  DB_USER: shop
  DB_PASSWORD: ch4ngeMe
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: backend
  labels: { app: redis, app.kubernetes.io/part-of: shop }
spec:
  replicas: 1
  selector: { matchLabels: { app: redis } }
  template:
    metadata: { labels: { app: redis } }
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports: [{ containerPort: 6379, name: redis }]
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits:   { cpu: 200m, memory: 128Mi }
          readinessProbe: { tcpSocket: { port: redis }, periodSeconds: 5 }
---
apiVersion: v1
kind: Service
metadata: { name: redis, namespace: backend }
spec:
  selector: { app: redis }
  ports: [{ name: redis, port: 6379, targetPort: redis }]
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: worker-sa, namespace: backend }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: config-reader, namespace: backend }
rules:
  - apiGroups: [""]
    resources: [configmaps]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: worker-config-reader, namespace: backend }
subjects: [{ kind: ServiceAccount, name: worker-sa, namespace: backend }]
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: config-reader }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: backend
  labels: { app: worker, app.kubernetes.io/part-of: shop }
spec:
  replicas: 2
  selector: { matchLabels: { app: worker } }
  template:
    metadata: { labels: { app: worker } }
    spec:
      serviceAccountName: worker-sa
      priorityClassName: business-critical
      initContainers:
        - name: wait-redis
          image: busybox:1.36
          command: ["sh", "-c", "until nslookup redis.backend.svc.cluster.local; do echo attente redis; sleep 2; done"]
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sh", "-c", "while true; do echo \"$(date) job traite (redis=$REDIS_HOST)\"; sleep 30; done"]
          envFrom:
            - configMapRef: { name: app-config }
          env:
            - name: DB_PASSWORD
              valueFrom: { secretKeyRef: { name: app-secret, key: DB_PASSWORD } }
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 50m, memory: 32Mi }
---
# Autorise l'HTTPRoute du namespace frontend a cibler le Service api (acces cross-namespace)
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata: { name: allow-frontend-routes, namespace: backend }
spec:
  from:
    - { group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: frontend }
  to:
    - { group: "", kind: Service, name: api }
EOF
apply_file "${SEED_DIR}/20-backend.yaml"

# ----------------------------------------------------------------- data
log "Namespace data : postgres (StatefulSet + PVC dynamique), NetworkPolicies, custom resources"
cat > "${SEED_DIR}/30-data.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata: { name: db-credentials, namespace: data }
type: Opaque
stringData:
  POSTGRES_USER: shop
  POSTGRES_PASSWORD: ch4ngeMe
  POSTGRES_DB: shop
---
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: data, labels: { app: postgres } }
spec:
  clusterIP: None
  selector: { app: postgres }
  ports: [{ name: pg, port: 5432, targetPort: pg }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: data
  labels: { app: postgres, app.kubernetes.io/part-of: shop }
spec:
  serviceName: postgres
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports: [{ containerPort: 5432, name: pg }]
          envFrom:
            - secretRef: { name: db-credentials }
          env:
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          readinessProbe:
            exec: { command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\""] }
            periodSeconds: 10
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: local-path
        resources: { requests: { storage: 1Gi } }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: data }
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-backend-to-postgres, namespace: data }
spec:
  podSelector: { matchLabels: { app: postgres } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: backend } }
      ports: [{ protocol: TCP, port: 5432 }]
---
apiVersion: ops.example.com/v1
kind: Backup
metadata: { name: postgres-nightly, namespace: data }
spec: { schedule: "0 2 * * *", target: postgres-0, retentionDays: 14 }
---
apiVersion: ops.example.com/v1
kind: Backup
metadata: { name: postgres-weekly, namespace: data }
spec: { schedule: "0 3 * * 0", target: postgres-0, retentionDays: 60 }
EOF
apply_file "${SEED_DIR}/30-data.yaml"

# ----------------------------------------------------------------- monitoring
log "Namespace monitoring : DaemonSet node-agent (tous les noeuds, hostPath), ClusterRole"
cat > "${SEED_DIR}/40-monitoring.yaml" <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata: { name: node-agent, namespace: monitoring }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: node-agent-reader }
rules:
  - apiGroups: [""]
    resources: [nodes, pods]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: node-agent-reader }
subjects: [{ kind: ServiceAccount, name: node-agent, namespace: monitoring }]
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: node-agent-reader }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
  namespace: monitoring
  labels: { app: node-agent }
spec:
  selector: { matchLabels: { app: node-agent } }
  template:
    metadata: { labels: { app: node-agent } }
    spec:
      serviceAccountName: node-agent
      tolerations:
        - { key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }
      containers:
        - name: agent
          image: busybox:1.36
          command: ["sh", "-c", "while true; do echo \"$(date) $NODE_NAME $(ls /host/var/log | wc -l) fichiers de log\"; sleep 60; done"]
          env:
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
          resources:
            requests: { cpu: 5m, memory: 8Mi }
            limits:   { cpu: 20m, memory: 16Mi }
          volumeMounts:
            - { name: varlog, mountPath: /host/var/log, readOnly: true }
      volumes:
        - name: varlog
          hostPath: { path: /var/log }
EOF
apply_file "${SEED_DIR}/40-monitoring.yaml"

# ----------------------------------------------------------------- batch
log "Namespace batch : CronJob + Job"
cat > "${SEED_DIR}/50-batch.yaml" <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata: { name: sales-report, namespace: batch }
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: report
              image: busybox:1.36
              command: ["sh", "-c", "echo \"$(date) rapport genere\""]
              resources:
                requests: { cpu: 5m, memory: 8Mi }
                limits:   { cpu: 50m, memory: 16Mi }
---
apiVersion: batch/v1
kind: Job
metadata: { name: db-migrate-v42, namespace: batch }
spec:
  backoffLimit: 2
  completions: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: busybox:1.36
          command: ["sh", "-c", "echo migration 42 appliquee; sleep 5"]
          resources:
            requests: { cpu: 5m, memory: 8Mi }
            limits:   { cpu: 50m, memory: 16Mi }
EOF
apply_file "${SEED_DIR}/50-batch.yaml"

# ----------------------------------------------------------------- team-a
log "Namespace team-a : quota, LimitRange, RBAC, sidecar, PVC statique"
cat > "${SEED_DIR}/60-team-a.yaml" <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata: { name: team-a-quota, namespace: team-a }
spec:
  hard:
    pods: "10"
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    persistentvolumeclaims: "3"
---
apiVersion: v1
kind: LimitRange
metadata: { name: team-a-defaults, namespace: team-a }
spec:
  limits:
    - type: Container
      default:        { cpu: 200m, memory: 128Mi }
      defaultRequest: { cpu: 50m,  memory: 64Mi }
      max:            { cpu: 500m, memory: 512Mi }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: developer, namespace: team-a }
rules:
  - apiGroups: ["", apps]
    resources: [pods, pods/log, services, configmaps, deployments, replicasets]
    verbs: [get, list, watch, create, update, patch, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: developer-alice, namespace: team-a }
subjects: [{ apiGroup: rbac.authorization.k8s.io, kind: User, name: alice }]
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: developer }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: ci-bot, namespace: team-a }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: ci-bot-edit, namespace: team-a }
subjects: [{ kind: ServiceAccount, name: ci-bot, namespace: team-a }]
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: edit }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sandbox
  namespace: team-a
  labels: { app: sandbox }
spec:
  replicas: 1
  selector: { matchLabels: { app: sandbox } }
  template:
    metadata: { labels: { app: sandbox } }
    spec:
      nodeSelector: { disk: ssd }
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "while true; do echo \"$(date) requete traitee\" >> /var/log/app/app.log; sleep 10; done"]
          volumeMounts: [{ name: logs, mountPath: /var/log/app }]
        - name: log-shipper
          image: busybox:1.36
          command: ["sh", "-c", "touch /var/log/app/app.log; tail -F /var/log/app/app.log"]
          volumeMounts: [{ name: logs, mountPath: /var/log/app, readOnly: true }]
      volumes:
        - name: logs
          emptyDir: {}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: archive-claim, namespace: team-a }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: manual
  resources: { requests: { storage: 1Gi } }
  selector: { matchLabels: { tier: archive } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: archiver
  namespace: team-a
  labels: { app: archiver }
spec:
  replicas: 1
  selector: { matchLabels: { app: archiver } }
  template:
    metadata: { labels: { app: archiver } }
    spec:
      containers:
        - name: archiver
          image: busybox:1.36
          command: ["sh", "-c", "while true; do date >> /archive/heartbeat; sleep 300; done"]
          volumeMounts: [{ name: archive, mountPath: /archive }]
      volumes:
        - name: archive
          persistentVolumeClaim: { claimName: archive-claim }
EOF
apply_file "${SEED_DIR}/60-team-a.yaml"

# ----------------------------------------------------------------- kustomize (materiel, non applique)
log "Materiel Kustomize dans ${KUSTOMIZE_DIR} (non applique)"
mkdir -p "${KUSTOMIZE_DIR}/base" "${KUSTOMIZE_DIR}/overlays/staging"
cat > "${KUSTOMIZE_DIR}/base/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: catalog, labels: { app: catalog } }
spec:
  replicas: 1
  selector: { matchLabels: { app: catalog } }
  template:
    metadata: { labels: { app: catalog } }
    spec:
      containers:
        - name: catalog
          image: nginx:1.27-alpine
          ports: [{ containerPort: 80 }]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 100m, memory: 64Mi }
EOF
cat > "${KUSTOMIZE_DIR}/base/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata: { name: catalog }
spec:
  selector: { app: catalog }
  ports: [{ port: 80, targetPort: 80 }]
EOF
cat > "${KUSTOMIZE_DIR}/base/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [deployment.yaml, service.yaml]
EOF
cat > "${KUSTOMIZE_DIR}/overlays/staging/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: staging
namePrefix: stg-
resources: [../../base]
labels:
  - pairs: { env: staging }
patches:
  - target: { kind: Deployment, name: catalog }
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
EOF
echo "  essai : kubectl kustomize ${KUSTOMIZE_DIR}/overlays/staging"

# ----------------------------------------------------------------- attente + bilan
log "Attente des workloads"
for target in "frontend deploy/web" "backend deploy/redis" "backend deploy/worker" "data statefulset/postgres" \
              "monitoring daemonset/node-agent" "team-a deploy/sandbox" "team-a deploy/archiver"; do
  set -- ${target}
  kubectl -n "$1" rollout status "$2" --timeout=300s || warn "$1/$2 pas pret : kubectl -n $1 describe $2"
done
kubectl -n batch wait --for=condition=complete job/db-migrate-v42 --timeout=180s >/dev/null || warn "job db-migrate-v42 non termine"

log "Bilan"
kubectl get ns --show-labels | grep -E 'team=|NAME' || true
echo
kubectl get pods -A -o wide --field-selector=status.phase!=Succeeded | grep -vE 'kube-system|calico|tigera' || true
echo
kubectl get pvc -A
echo
kubectl get gateway,httproute -A 2>/dev/null || true
echo
NODE_IP=$(kubectl get node "${W1}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
cat <<EOF

Termine. Tests rapides :
  curl -H 'Host: shop.local'        http://${NODE_IP}:30080/        # Gateway API -> web
  curl -H 'Host: shop.local'        http://${NODE_IP}:30080/api     # Gateway API -> backend/api (ReferenceGrant)
  curl -H 'Host: legacy.shop.local' http://${NODE_IP}:30080/        # Ingress -> web
  kubectl top nodes                                                 # metrics-server (~1 min apres install)
  kubectl get bk -A                                                 # custom resources
Pense au snapshot depuis Windows :  .\\cka-lab.ps1 -Action Snapshot -SnapshotName seeded
EOF
