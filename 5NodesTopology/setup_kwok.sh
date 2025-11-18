#!/bin/bash
set -euo pipefail

echo "===== [1/12] Patching metrics-server TLS ====="
k3s kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' || true

echo "===== [2/12] Installing KWOK Controller (v0.7.0) ====="
k3s kubectl create ns kwok-system --dry-run=client -o yaml | k3s kubectl apply -f -
k3s kubectl -n kwok-system create serviceaccount kwok-controller --dry-run=client -o yaml | k3s kubectl apply -f -

# RBAC for KWOK controller
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kwok-controller
rules:
  - apiGroups: [""]
    resources: ["pods","pods/status","nodes","nodes/status","services","endpoints","namespaces"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: ["apps"]
    resources: ["deployments","daemonsets","replicasets","statefulsets"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: ["kwok.x-k8s.io","metrics.k8s.io"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kwok-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kwok-controller
subjects:
  - kind: ServiceAccount
    name: kwok-controller
    namespace: kwok-system
YAML

# KWOK controller
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kwok-controller
  namespace: kwok-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: kwok-controller}
  template:
    metadata:
      labels: {app: kwok-controller}
    spec:
      serviceAccountName: kwok-controller
      tolerations:
        - operator: "Exists"
      containers:
        - name: kwok-controller
          image: registry.k8s.io/kwok/kwok:v0.7.0
          args: ["--manage-all-nodes","--v=2"]
          imagePullPolicy: IfNotPresent
YAML

echo "Waiting for KWOK controller rollout..."
k3s kubectl -n kwok-system rollout status deploy/kwok-controller --timeout=180s || true

echo "===== [3/12] Installing KWOK CRDs ====="
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: stages.kwok.x-k8s.io
spec:
  group: kwok.x-k8s.io
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              x-kubernetes-preserve-unknown-fields: true
  scope: Cluster
  names:
    plural: stages
    singular: stage
    kind: Stage
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: metrics.kwok.x-k8s.io
spec:
  group: kwok.x-k8s.io
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              x-kubernetes-preserve-unknown-fields: true
            usage:
              type: object
              x-kubernetes-preserve-unknown-fields: true
  scope: Namespaced
  names:
    plural: metrics
    singular: metric
    kind: Metric
YAML

echo "===== [4/12] Creating Pod Lifecycle Stages ====="
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: kwok.x-k8s.io/v1alpha1
kind: Stage
metadata:
  name: pod-create
spec:
  resourceRef: {apiGroup: v1, kind: Pod}
  selector:
    matchExpressions:
      - key: '.metadata.deletionTimestamp'
        operator: 'DoesNotExist'
  next:
    statusTemplate: |
      {{ $now := Now }}
      conditions:
      - lastTransitionTime: {{ $now }}
        status: "True"
        type: Initialized
      - lastTransitionTime: {{ $now }}
        status: "True"
        type: Ready
      - lastTransitionTime: {{ $now }}
        status: "True"
        type: ContainersReady
      containerStatuses:
      {{ range .spec.containers }}
      - image: {{ .image }}
        name: {{ .name }}
        ready: true
        restartCount: 0
        state:
          running:
            startedAt: {{ $now }}
      {{ end }}
      hostIP: 10.0.0.1
      phase: Running
      podIP: {{ .metadata.annotations.PodIP }}
      startTime: {{ $now }}
---
apiVersion: kwok.x-k8s.io/v1alpha1
kind: Stage
metadata:
  name: pod-delete
spec:
  resourceRef: {apiGroup: v1, kind: Pod}
  selector:
    matchExpressions:
      - key: '.metadata.deletionTimestamp'
        operator: 'Exists'
  next:
    delete: true
YAML

echo "===== [5/12] Creating Fake Nodes ====="
for i in 1 2 3; do
cat <<YAML | k3s kubectl apply -f -
apiVersion: v1
kind: Node
metadata:
  name: fake-node-$i
  labels:
    node-role.kubernetes.io/worker: ""
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
    type: kwok
  annotations:
    kwok.x-k8s.io/node: "fake"
    node.alpha.kubernetes.io/ttl: "0"
spec:
  taints:
  - key: kwok.x-k8s.io/node
    value: fake
    effect: NoSchedule
status:
  capacity: {cpu: "16", memory: "64Gi", pods: "200"}
  allocatable: {cpu: "16", memory: "64Gi", pods: "200"}
  addresses:
    - type: InternalIP
      address: 10.0.0.$((i+10))
    - type: Hostname
      address: fake-node-$i
  nodeInfo:
    architecture: amd64
    kubeProxyVersion: fake
    kubeletVersion: fake
    operatingSystem: linux
YAML
done

echo "===== [6/12] Adding Heartbeat Interval ====="
for i in 1 2 3; do
  k3s kubectl annotate node fake-node-$i kwok.x-k8s.io/heartbeat-interval="30s" --overwrite || true
done

echo "===== [7/12] Waiting for Fake Nodes to become Ready ====="
timeout=120; interval=5; elapsed=0
while true; do
  ready_nodes=$(k3s kubectl get nodes | grep -c "fake-node-[123].*Ready" || true)
  if [ "$ready_nodes" -eq 3 ]; then echo "All fake nodes are Ready."; break; fi
  if [ "$elapsed" -ge "$timeout" ]; then echo "Timeout waiting for fake nodes (after ${timeout}s)."; break; fi
  echo "Waiting... (${elapsed}s elapsed)"; sleep $interval; elapsed=$((elapsed + interval))
done

echo "===== [8/12] Demo namespace + fake pods ====="
k3s kubectl create ns demo --dry-run=client -o yaml | k3s kubectl apply -f -
k3s kubectl -n demo delete pod -l app=demo-power --ignore-not-found
for i in $(seq 1 30); do
  n=$(( (i - 1) % 3 + 1 ))
  cat <<YAML | k3s kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-$i
  namespace: demo
  labels: {app: demo-power}
  annotations:
    kwok.x-k8s.io/usage-cpu: "500m"
    kwok.x-k8s.io/usage-memory: "200Mi"
spec:
  nodeName: fake-node-$n
  containers: [{name: nop, image: registry.k8s.io/pause:3.9}]
YAML
done

echo "===== [9/12] Metrics objects for pods ====="
for i in $(seq 1 30); do
cat <<YAML | k3s kubectl apply -f -
apiVersion: kwok.x-k8s.io/v1alpha1
kind: Metric
metadata:
  name: test-pod-$i
  namespace: demo
spec:
  kind: Pod
  usage: {cpu: 500m, memory: 200Mi}
YAML
done

echo "===== [10/12] Metrics Bridge (HTTPS, PSI in annotations only) ====="
# SA + RBAC
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata: {name: kwok-metrics-bridge, namespace: kwok-system}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: kwok-metrics-bridge}
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "services"]
    verbs: ["get","list","watch"]
  - apiGroups: ["kwok.x-k8s.io"]
    resources: ["metrics"]
    verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: kwok-metrics-bridge}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: kwok-metrics-bridge}
subjects: [{kind: ServiceAccount, name: kwok-metrics-bridge, namespace: kwok-system}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: kwok-metrics-bridge:system:auth-delegator}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: system:auth-delegator}
subjects: [{kind: ServiceAccount, name: kwok-metrics-bridge, namespace: kwok-system}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: kwok-metrics-bridge-auth-reader, namespace: kube-system}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: extension-apiserver-authentication-reader}
subjects: [{kind: ServiceAccount, name: kwok-metrics-bridge, namespace: kwok-system}]
YAML

# TLS secret
k3s kubectl -n kwok-system delete secret kwok-metrics-certs --ignore-not-found
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout /tmp/tls.key -out /tmp/tls.crt \
  -subj "/CN=kwok-metrics.kwok-system.svc" \
  -addext "subjectAltName=DNS:kwok-metrics.kwok-system.svc,DNS:kwok-metrics.kwok-system.svc.cluster.local" 2>/dev/null
k3s kubectl -n kwok-system create secret tls kwok-metrics-certs --cert=/tmp/tls.crt --key=/tmp/tls.key

# Bridge code (PSI only in annotations)
cat > /tmp/metrics_bridge.py << 'PYEOF'
from flask import Flask, jsonify
from kubernetes import client, config
from datetime import datetime, timezone
import logging, sys, random, requests
logging.basicConfig(level=logging.INFO, stream=sys.stdout)
app = Flask(__name__)
config.load_incluster_config()
v1 = client.CoreV1Api()
custom = client.CustomObjectsApi()
MS = "https://metrics-server.kube-system.svc:443"
def now(): return datetime.now(timezone.utc).isoformat()

@app.route('/healthz')
def health(): return 'ok', 200

@app.route('/apis')
def apis():
    return jsonify({"kind":"APIGroupList","apiVersion":"v1","groups":[
        {"name":"metrics.k8s.io","versions":[{"groupVersion":"metrics.k8s.io/v1beta1","version":"v1beta1"}],
         "preferredVersion":{"groupVersion":"metrics.k8s.io/v1beta1","version":"v1beta1"}}
    ]})

@app.route('/apis/metrics.k8s.io')
def group():
    return jsonify({"kind":"APIGroup","apiVersion":"v1","name":"metrics.k8s.io",
                    "versions":[{"groupVersion":"metrics.k8s.io/v1beta1","version":"v1beta1"}],
                    "preferredVersion":{"groupVersion":"metrics.k8s.io/v1beta1","version":"v1beta1"}})

@app.route('/apis/metrics.k8s.io/v1beta1')
def resources():
    return jsonify({"kind":"APIResourceList","apiVersion":"v1","groupVersion":"metrics.k8s.io/v1beta1",
                    "resources":[{"name":"nodes","namespaced":False,"kind":"NodeMetrics","verbs":["get","list"]},
                                 {"name":"pods","namespaced":True,"kind":"PodMetrics","verbs":["get","list"]}]})

def ms(path):
    try:
        r = requests.get(MS+path, timeout=3, verify=False)
        r.raise_for_status()
        return r.json()
    except Exception:
        return None

@app.route('/apis/metrics.k8s.io/v1beta1/nodes')
def nodes_metrics():
    items=[]
    all_nodes = v1.list_node().items
    ms_nodes = ms("/apis/metrics.k8s.io/v1beta1/nodes") or {"items":[]}
    ms_map = {it.get("metadata",{}).get("name",""): it for it in ms_nodes.get("items", []) if it.get("metadata")}
    for n in all_nodes:
        name = n.metadata.name
        is_kwok = (n.metadata.labels or {}).get("type") == "kwok"
        if is_kwok:
            cpu_m = 0; mem_mi = 0
            pods = v1.list_pod_for_all_namespaces(field_selector=f"spec.nodeName={name}")
            for p in pods.items:
                try:
                    m = custom.get_namespaced_custom_object("kwok.x-k8s.io","v1alpha1",p.metadata.namespace,"metrics",p.metadata.name)
                    u = m.get("spec",{}).get("usage",{})
                    cpu_m  += int(str(u.get("cpu","0m")).replace("m",""))
                    mem_mi += int(str(u.get("memory","0Mi")).replace("Mi",""))
                except Exception: pass
            psi = f"{round(random.uniform(0.5,5.0),2)}%"
            items.append({
                "metadata":{"name":name,"annotations":{"psi.cpu": psi}},
                "timestamp":now(),"window":"30s",
                "usage":{"cpu":f"{cpu_m}m","memory":f"{mem_mi}Mi"}
            })
        else:
            base = ms_map.get(name) or ms(f"/apis/metrics.k8s.io/v1beta1/nodes/{name}")
            if isinstance(base, dict) and base.get("usage"):
                base.setdefault("metadata",{}).setdefault("annotations",{})["psi.cpu"] = f"{round(random.uniform(0.5,3.0),2)}%"
                items.append(base)
            else:
                items.append({
                    "metadata":{"name":name,"annotations":{"psi.cpu":"n/a"}},
                    "timestamp":now(),"window":"30s",
                    "usage":{"cpu":"0m","memory":"0Mi"}
                })
    return jsonify({"kind":"NodeMetricsList","apiVersion":"metrics.k8s.io/v1beta1","items":items})

@app.route('/apis/metrics.k8s.io/v1beta1/namespaces/<ns>/pods')
def pods_metrics(ns):
    proxy = ms(f"/apis/metrics.k8s.io/v1beta1/namespaces/{ns}/pods")
    if proxy and "items" in proxy: return jsonify(proxy)
    items=[]
    pods = v1.list_namespaced_pod(ns)
    for p in pods.items:
        try:
            m = custom.get_namespaced_custom_object("kwok.x-k8s.io","v1alpha1",ns,"metrics",p.metadata.name)
            u = m.get("spec",{}).get("usage",{})
            items.append({"metadata":{"name":p.metadata.name,"namespace":ns},
                          "timestamp":now(),"window":"30s",
                          "containers":[{"name":c.name,"usage":{"cpu":u.get("cpu","0m"),"memory":u.get("memory","0Mi")}} for c in p.spec.containers]})
        except Exception: pass
    return jsonify({"kind":"PodMetricsList","apiVersion":"metrics.k8s.io/v1beta1","items":items})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8443, ssl_context=('/certs/tls.crt','/certs/tls.key'))
PYEOF

k3s kubectl -n kwok-system create configmap metrics-bridge-code --from-file=app.py=/tmp/metrics_bridge.py \
  -o yaml --dry-run=client | k3s kubectl apply -f -

# Deployment + Service
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kwok-metrics-bridge
  namespace: kwok-system
spec:
  replicas: 1
  selector: {matchLabels: {app: kwok-metrics-bridge}}
  template:
    metadata: {labels: {app: kwok-metrics-bridge}}
    spec:
      serviceAccountName: kwok-metrics-bridge
      containers:
      - name: bridge
        image: python:3.11-slim
        command: ["/bin/bash","-c"]
        args:
        - |
          set -e
          apt-get update -qq && apt-get install -y -qq curl >/dev/null 2>&1
          pip install --quiet kubernetes flask requests
          cp /config/app.py /app.py
          python /app.py
        ports: [{containerPort: 8443, name: https}]
        volumeMounts:
        - {name: certs, mountPath: /certs, readOnly: true}
        - {name: config, mountPath: /config}
        livenessProbe:
          httpGet: {path: /healthz, port: https, scheme: HTTPS}
          initialDelaySeconds: 20
          periodSeconds: 10
        readinessProbe:
          httpGet: {path: /healthz, port: https, scheme: HTTPS}
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - {name: certs, secret: {secretName: kwok-metrics-certs}}
      - {name: config, configMap: {name: metrics-bridge-code}}
---
apiVersion: v1
kind: Service
metadata: {name: kwok-metrics, namespace: kwok-system}
spec:
  selector: {app: kwok-metrics-bridge}
  ports:
  - name: https
    port: 443
    targetPort: 8443
YAML

echo "===== [11/12] Registering Metrics APIService ====="
k3s kubectl delete apiservice v1beta1.metrics.k8s.io --ignore-not-found
cat <<'YAML' | k3s kubectl apply -f -
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata: {name: v1beta1.metrics.k8s.io}
spec:
  service:
    name: kwok-metrics
    namespace: kwok-system
    port: 443
  group: metrics.k8s.io
  version: v1beta1
  insecureSkipTLSVerify: true
  groupPriorityMinimum: 100
  versionPriority: 100
YAML

echo "Waiting for metrics bridge rollout..."
k3s kubectl -n kwok-system rollout status deploy/kwok-metrics-bridge --timeout=180s || true

echo "===== [12/12] Install kubectl-fake-top (reads PSI from annotations) ====="
cat >/usr/local/bin/kubectl-fake-top <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
KCTL="${KCTL:-k3s kubectl}"
if ! command -v jq >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then yum install -y -q jq >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache jq >/dev/null 2>&1 || true
  fi
fi
if ! command -v jq >/dev/null 2>&1; then echo "[kubectl-fake-top] jq is required"; exit 1; fi
printf "%-15s %-10s %-12s %-8s\n" "NAME" "CPU" "MEMORY" "PSI(CPU)"
${KCTL} get --raw /apis/metrics.k8s.io/v1beta1/nodes | jq -r '
  .items[] |
  [
    .metadata.name,
    .usage.cpu,
    .usage.memory,
    (.metadata.annotations["psi.cpu"] // "n/a")
  ] | @tsv
' | while IFS=$'\t' read -r name cpu mem psi; do
  printf "%-15s %-10s %-12s %-8s\n" "$name" "$cpu" "$mem" "$psi"
done
EOF
chmod +x /usr/local/bin/kubectl-fake-top
ln -sf /usr/local/bin/kubectl-fake-top /usr/local/bin/kubectl-fake-too || true

# Final info
k3s kubectl get nodes || true
k3s kubectl -n kwok-system get pods -o wide || true
k3s kubectl get apiservice v1beta1.metrics.k8s.io -o wide || true
k3s kubectl -n kwok-system get endpoints kwok-metrics -o wide || true

echo "===== READY ====="
echo "Now try:"
echo "  k3s kubectl top nodes            # should work"
echo "  kubectl-fake-top                 # shows PSI(CPU) from annotations"

