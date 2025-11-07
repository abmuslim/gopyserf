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

## Running Sellers and Buyer

To start sellers, run:
```bash
./start_sellers.sh
```

To run the buyer:
```bash
./config_buyer.sh
```

Then run:
```bash
python3 service_discovery_v6.py --geom-url http://172.20.20.17:4040/cluster-status --rtt-threshold-ms 12 --rpc-addr 127.0.0.1:7373 --timeout-s 8 --sort score_per_cpu --limit 30 --buyer-url http://127.0.0.1:8090/buyer --http-serve --http-host 0.0.0.0 --http-port 4041 --http-path /hilbert-output --loop --busy-secs 30
```

> ⚠️ **Note:** Update the `--geom-url` IP (`http://172.20.20.17:4040/cluster-status`) to match the IP of **serf1** (e.g., `172.20.20.XX`).

## Note

- **Liqo is not included** in this setup.
