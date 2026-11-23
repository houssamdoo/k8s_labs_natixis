# Kubernetes HA Cluster: kubeadm + CRI-O + Calico + MetalLB + Headlamp


| Component         | Version / detail                                                                                         |
|-------------------|----------------------------------------------------------------------------------------------------------|
| Kubernetes        | v1.37.2 (kubeadm, `kubeadm.k8s.io/v1beta4`)                                                              |
| Container runtime | CRI-O v1.37.3 (**not** containerd)                                                                       |
| CNI               | Calico v3.29.3, pool `10.244.0.0/16`, IPIP `Always`, VXLAN `Never`                                       |
| Pod CIDR          | `10.244.0.0/16`                                                                                          |
| Service CIDR      | `10.96.0.0/12`                                                                                           |
| LoadBalancer      | MetalLB v0.16.2, L2 mode, pool `10.10.10.240-10.10.10.250`                                               |
| Dashboard         | Headlamp v0.46.0 (Helm chart `headlamp-0.46.0`) — this cluster uses Headlamp, not `kubernetes-dashboard` |
| Topology          | 3 control-plane (`k8s-master-01/02/03`), 2 workers (`k8s-worker-01/02`)                                  |


## 0. Environment Variables

Export these on **every node** before starting (or template them into your provisioning tool). Values below match the live cluster exactly:

```bash
# --- Kubernetes ---
export K8S_VERSION="v1.37"            # apt repo track (pkgs.k8s.io core:/stable:/v1.37)
export POD_CIDR="10.244.0.0/16"
export SERVICE_CIDR="10.96.0.0/12"
export CP_ENDPOINT="10.10.10.11:6443" # master-01 IP:6443 — see Appendix to use a real VIP instead

# --- Node inventory ---
export MASTER_01_IP="10.10.10.11"
export MASTER_02_IP="10.10.10.12"
export MASTER_03_IP="10.10.10.13"
export WORKER_01_IP="10.10.10.21"
export WORKER_02_IP="10.10.10.22"

# --- Container runtime ---
export CRIO_VERSION="v1.37"           # must track K8S_VERSION's minor
export CRI_SOCKET="unix:///var/run/crio/crio.sock"

# --- Add-ons ---
export CALICO_VERSION="v3.29.3"
export METALLB_VERSION="v0.16.2"
export METALLB_POOL="10.10.10.240-10.10.10.250"
```


## Phase 1: Base OS Prep (ALL 5 nodes)

### 1.1 `/etc/hosts`

```bash
sudo tee -a /etc/hosts <<EOF
${MASTER_01_IP} k8s-master-01
${MASTER_02_IP} k8s-master-02
${MASTER_03_IP} k8s-master-03
${WORKER_01_IP} k8s-worker-01
${WORKER_02_IP} k8s-worker-02
EOF
```
Verify: `ping -c2 k8s-master-01`

### 1.2 Disable swap permanently

```bash
sudo swapoff -a
sudo sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
```
Verify: `free -m` → `Swap:` total must be `0`.

### 1.3 Kernel modules

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
```
Verify: `lsmod | grep -E "(overlay|br_netfilter)"`

### 1.4 Sysctl

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```
Verify: `sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward` — all `= 1`.

---

## Phase 2: Install CRI-O (ALL 5 nodes)

No containerd is installed at any point — CRI-O is the only runtime on these nodes.

```bash
sudo apt-get update
sudo apt-get install -y curl gpg software-properties-common

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/cri-o.list

sudo apt-get update
sudo apt-get install -y cri-o

sudo systemctl daemon-reload
sudo systemctl enable --now crio

# ====================================================================================== #

sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y cri-tools

```

Verify CRI-O is active and its cgroup driver matches what kubelet will expect (`systemd`):

```bash
sudo systemctl is-active crio
sudo crio config 2>/dev/null | grep cgroup_manager   # expect: cgroup_manager = "systemd"
```

Point `crictl` at CRI-O:

```bash
sudo crictl config runtime-endpoint "${CRI_SOCKET}"
sudo crictl config image-endpoint "${CRI_SOCKET}"
sudo crictl info >/dev/null && echo "crio OK"
```


## Phase 3: Install kubeadm, kubelet, kubectl (ALL 5 nodes)

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet
```

Verify:
```bash
kubeadm version
kubectl version --client=true
kubelet --version
```
*Kubelet will crash-loop until `kubeadm init`/`join` runs — expected.*


## Phase 4: Initialize Control Plane (`k8s-master-01` ONLY)

```bash
sudo kubeadm init \
  --control-plane-endpoint "${CP_ENDPOINT}" \
  --apiserver-advertise-address "${MASTER_01_IP}" \
  --pod-network-cidr "${POD_CIDR}" \
  --service-cidr "${SERVICE_CIDR}" \
  --cri-socket "${CRI_SOCKET}" \
  --upload-certs
```

> `kubeadm init` prints two join commands at the end — **save both**: the control-plane join (with `--control-plane`/`--certificate-key`) and the worker join (token + CA hash only).

### 4.1 Local `kubectl` access

```bash
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```
Verify: `kubectl get nodes` → `k8s-master-01` is `NotReady` (waiting on CNI — expected).


## Phase 5: Install Calico CNI (`k8s-master-01` ONLY)

Calico's default pool is `192.168.0.0/16` — override it to match `${POD_CIDR}` so it lines up with what `kubeadm init --pod-network-cidr` already told the API server:

```bash
curl -fsSL -o calico.yaml \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# Uncomment and set CALICO_IPV4POOL_CIDR to ${POD_CIDR} under the calico-node
# container env in calico.yaml, then apply.
sed -i -E \
  -e 's/^([[:space:]]*)#[[:space:]]*- name: CALICO_IPV4POOL_CIDR$/\1- name: CALICO_IPV4POOL_CIDR/' \
  -e 's/^([[:space:]]*)#[[:space:]]*value: "192\.168\.0\.0\/16"$/\1  value: "10.244.0.0\/16"/' \
  calico.yaml
kubectl apply -f calico.yaml
```

Verify:
```bash
kubectl get pods -n kube-system -l k8s-app=calico-node -w   # wait for all Running, then Ctrl+C
kubectl get nodes                                            # master-01 -> Ready
```


## Phase 6: Join Additional Masters (`k8s-master-02`, `k8s-master-03`)

Generate/regenerate the control-plane join command on `k8s-master-01` (certificate key expires after 2h):

```bash
export CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -1)
sudo kubeadm token create --print-join-command
#sudo kubeadm token create --print-join-command --certificate-key "${CERT_KEY}"
```

On **`k8s-master-02`**:
```bash
sudo kubeadm join "${CP_ENDPOINT}" \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key> \
  --apiserver-advertise-address "${MASTER_02_IP}" \
  --cri-socket "${CRI_SOCKET}"
```

On **`k8s-master-03`** (same, with `${MASTER_03_IP}`):
```bash
sudo kubeadm join "${CP_ENDPOINT}" \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key> \
  --apiserver-advertise-address "${MASTER_03_IP}" \
  --cri-socket "${CRI_SOCKET}"
```

*(Optional)* copy `admin.conf` to `$HOME/.kube/config` on masters 02/03 as in Phase 4.1.

Verify (from `k8s-master-01`):
```bash
kubectl get nodes -o wide

sudo ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  --endpoints="https://${MASTER_01_IP}:2379,https://${MASTER_02_IP}:2379,https://${MASTER_03_IP}:2379" \
  endpoint health
```


## Phase 7: Join Workers (`k8s-worker-01`, `k8s-worker-02`)

```bash
kubeadm token create --print-join-command   # run on k8s-master-01 if the original token expired
```

On **both** workers:
```bash
sudo kubeadm join "${CP_ENDPOINT}" \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --cri-socket "${CRI_SOCKET}"
```

Verify (`k8s-master-01`):
```bash
kubectl get nodes
kubectl label node k8s-worker-01 node-role.kubernetes.io/worker=""
kubectl label node k8s-worker-02 node-role.kubernetes.io/worker=""
```


## Phase 8: Install MetalLB (`k8s-master-01` ONLY)

MetalLB's native manifest requires the `metallb-system` namespace to run under the `privileged` Pod Security Standard (the speaker needs host networking/`NET_RAW`):

```bash
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

kubectl label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

Wait for it to roll out:
```bash
kubectl wait --for=condition=Ready pod -l app=metallb -n metallb-system --timeout=120s
```

> **Recommended for L2 mode:** enable `strictARP` in the `kube-proxy` ConfigMap so ARP announcements from MetalLB's speaker aren't dropped by `kube-proxy`'s own ARP handling. (The live cluster currently runs with `strictARP: false` and it still works, but MetalLB's own docs call this out as the correct L2 setting — fix it if you hit flaky LoadBalancer IP failover.)
> ```bash
> kubectl get configmap kube-proxy -n kube-system -o yaml | \
>   sed -e "s/strictARP: false/strictARP: true/" | \
>   kubectl apply -f - -n kube-system
> kubectl rollout restart daemonset kube-proxy -n kube-system
> ```

Create the address pool and L2 advertisement:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - lab-pool
EOF
```

Verify:
```bash
kubectl get ipaddresspool,l2advertisement -n metallb-system
```


## Phase 9: Install Headlamp Dashboard (`k8s-master-01` ONLY)

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update

helm upgrade --install headlamp headlamp/headlamp \
  --namespace headlamp \
  --create-namespace
```

Verify: `kubectl get pods -n headlamp` → `1/1 Running`.

### 9.1 Admin ServiceAccount + RBAC

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp-admin
  namespace: headlamp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: headlamp-admin
  namespace: headlamp
EOF
```

### 9.2 Login token

```bash
kubectl create token headlamp-admin -n headlamp --duration=8760h
```

### 9.3 Expose it (NodePort, persistent across the LAN)

```bash
kubectl patch svc headlamp -n headlamp -p '{"spec": {"type": "NodePort"}}'
kubectl get svc headlamp -n headlamp   # note the nodePort, e.g. 80:31992/TCP
```

Browse to `http://<any-node-ip>:<nodePort>` and paste the token from 9.2.


## Phase 10: Smoke Test Everything Together

```bash
# 1. Pod scheduling + Calico cross-node networking + CoreDNS
kubectl create deployment apache --image=httpd:latest --replicas=2
kubectl expose deployment apache --port=80 --type=NodePort
kubectl get pods -l app=apache -o wide
NODEPORT=$(kubectl get svc apache -o jsonpath='{.spec.ports[0].nodePort}')
curl -I "http://${WORKER_01_IP}:${NODEPORT}"

# 2. MetalLB LoadBalancer path
kubectl expose deployment apache --name=apache-lb --port=80 --type=LoadBalancer
kubectl get svc apache-lb -w   # wait for EXTERNAL-IP from ${METALLB_POOL}, Ctrl+C
LB_IP=$(kubectl get svc apache-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -I "http://${LB_IP}"

# 3. Cleanup
kubectl delete svc apache apache-lb
kubectl delete deployment apache
```



## Final Verification Checklist

```bash
kubectl get nodes -o wide                              # all Ready, CONTAINER-RUNTIME = cri-o://1.37.x
kubectl get pods -n kube-system -l k8s-app=calico-node # 5/5 Running
kubectl get pods -n metallb-system                     # controller + 5 speakers Running
kubectl get pods -n headlamp                           # 1/1 Running
kubectl get ipaddresspool,l2advertisement -n metallb-system
```
