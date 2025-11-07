# Century – 5 Node K3s Cluster

This setup creates a **5-node K3s cluster** using **Containerlab** with one switch and five Linux nodes.

---

## Topology

```
switch_a
 ├── serf1
 ├── serf2
 ├── serf3
 ├── serf4
 └── serf5
```

---

## How to Run

1. Run the orchestration script:
   ```bash
   ./orchestrated.sh
   ```

   > It will take some time to pull the Docker images and start all pods.

2. If the pods are **not running** on any node, run:
   ```bash
   for i in {1..5}; do echo "[serf$i] applying manifests..."; sudo docker exec -i clab-century-serf$i bash -lc 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; for f in /tmp/qos-controller-daemonset.yaml /tmp/service-account.yaml /tmp/cluster-role.yaml /tmp/cluster-role-binding.yaml /tmp/deployment-scheduler.yaml /tmp/ram_price.yaml /tmp/storage_price.yaml /tmp/vcpu_price.yaml /tmp/vgpu_price.yaml; do if [ -s "$f" ]; then echo "  applying $f..."; k3s kubectl apply -f "$f" || echo "  [warn] failed $f"; fi; done'; done
   ```

3. To check if all pods are running on all nodes:
   ```bash
   for i in {1..5}; do echo -e "\n====== [serf$i] ======"; sudo docker exec -i clab-century-serf$i bash -lc 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; k3s kubectl get pods -A -o wide --no-headers || echo "k3s not ready"'; done
   ```

---

## Note

- **Liqo is not included** in this setup.
