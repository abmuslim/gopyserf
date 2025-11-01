#!/usr/bin/env bash
set -euo pipefail

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# 1) pull pod metrics (CPU m, Mem Mi)
k3s kubectl top pod -A --no-headers \
 | awk '{printf "%s|%s\t%s\t%s\n",$1,$2,$3,$4}' \
 > "$TMPD/pod.metrics"

# 2) map pods -> nodes
k3s kubectl get pod -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName \
  --no-headers \
 | awk '{printf "%s|%s\t%s\n",$1,$2,$3}' \
 > "$TMPD/pod.nodes"

# 3) join & sum per-node
join -t $'\t' -1 1 -2 1 <(sort "$TMPD/pod.metrics") <(sort "$TMPD/pod.nodes") \
 | awk -F'\t' '
   {
     split($2,m,"m");        # CPU ends with m
     split($3,mm,"Mi");      # Mem ends with Mi
     node=$4
     cpu[node]+=m[1]
     mem[node]+=mm[1]
   }
   END {
     printf "%-20s %-12s %-12s\n","NODE","CPU(cores)","MEMORY(bytes)"
     for (n in cpu) {
       # convert m -> cores with 2 decimals; Mi -> bytes
       cores = cpu[n]/1000.0
       bytes = mem[n]*1024*1024
       printf "%-20s %-12.2f %-12d\n", n, cores, bytes
     }
   }' | sort
NODE                 CPU(cores)   MEMORY(bytes)
serf1                0.01         48234496    
root@serf1:/# join -t $'\t' -1 1 -2 1 <(sort "$TMPD/pod.metrics") <(sort "$TMPD/pod.nodes")  | awk -F'\t' '
   {
     split($2,m,"m");        # CPU ends with m
     split($3,mm,"Mi");      # Mem ends with Mi
     node=$4
     cpu[node]+=m[1]
     mem[node]+=mm[1]
   }
   END {
     printf "%-20s %-12s %-12s\n","NODE","CPU(cores)","MEMORY(bytes)"
     for (n in cpu) {
       # convert m -> cores with 2 decimals; Mi -> bytes
       cores = cpu[n]/1000.0
       bytes = mem[n]*1024*1024
       printf "%-20s %-12.2f %-12d\n", n, cores, bytes
     }
   }' | sort
NODE                 CPU(cores)   MEMORY(bytes)
serf1                0.01         48234496    




sudo tee /usr/local/bin/kubetop-nodes >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
k3s kubectl top pod -A --no-headers | awk '{printf "%s|%s\t%s\t%s\n",$1,$2,$3,$4}' > "$TMPD/pod.metrics"
k3s kubectl get pod -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName --no-headers \
  | awk '{printf "%s|%s\t%s\n",$1,$2,$3}' > "$TMPD/pod.nodes"
join -t $'\t' -1 1 -2 1 <(sort "$TMPD/pod.metrics") <(sort "$TMPD/pod.nodes") \
| awk -F'\t' '
  {
    split($2,m,"m"); split($3,mm,"Mi");
    node=$4; cpu[node]+=m[1]; mem[node]+=mm[1]
  }
  END {
    printf "%-20s %-12s %-12s\n","NODE","CPU(cores)","MEMORY(bytes)"
    for (n in cpu) printf "%-20s %-12.2f %-12d\n", n, cpu[n]/1000.0, mem[n]*1024*1024
  }' | sort
EOF

sudo chmod +x /usr/local/bin/kubetop-nodes
