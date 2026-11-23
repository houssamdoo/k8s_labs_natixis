#!/usr/bin/env bash
# =============================================================================
# Options:
#   -y, --yes           no confirmation
#   --skip-smoke-test   skip phase 10
#   --no-headlamp       skip phase 9
# Every variable in the "Settings" block can be overridden from the env,
# e.g.  SSH_PASS=secret ./setup-v2.sh -y
# =============================================================================
set -Eeuo pipefail

# ------------------------------- Settings ------------------------------------
K8S_VERSION="${K8S_VERSION:-v1.37}"            # pkgs.k8s.io track
CRIO_VERSION="${CRIO_VERSION:-v1.37}"          # must track K8S_VERSION minor
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
NODE_SUBNET="${NODE_SUBNET:-10.10.10.0/24}"    # used by Calico IP autodetection
CRI_SOCKET="${CRI_SOCKET:-unix:///var/run/crio/crio.sock}"

MASTER_01_IP="${MASTER_01_IP:-10.10.10.11}"
MASTER_02_IP="${MASTER_02_IP:-10.10.10.12}"
MASTER_03_IP="${MASTER_03_IP:-10.10.10.13}"
WORKER_01_IP="${WORKER_01_IP:-10.10.10.21}"
WORKER_02_IP="${WORKER_02_IP:-10.10.10.22}"
CP_ENDPOINT="${CP_ENDPOINT:-${MASTER_01_IP}:6443}"

CALICO_VERSION="${CALICO_VERSION:-v3.29.3}"
METALLB_VERSION="${METALLB_VERSION:-v0.16.2}"
METALLB_POOL="${METALLB_POOL:-10.10.10.240-10.10.10.250}"
HEADLAMP_CHART_VERSION="${HEADLAMP_CHART_VERSION:-}"   # empty = latest chart

SSH_USER="${SSH_USER:-$(id -un)}"
SSH_PASS="${SSH_PASS:-ubuntu}"                 # only used to push the SSH key

# Node inventory: "name ip role"
NODES=(
  "k8s-master-01 ${MASTER_01_IP} master"
  "k8s-master-02 ${MASTER_02_IP} master"
  "k8s-master-03 ${MASTER_03_IP} master"
  "k8s-worker-01 ${WORKER_01_IP} worker"
  "k8s-worker-02 ${WORKER_02_IP} worker"
)

ASSUME_YES=0; SMOKE_TEST=1; HEADLAMP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)          ASSUME_YES=1 ;;
    --skip-smoke-test) SMOKE_TEST=0 ;;
    --no-headlamp)     HEADLAMP=0 ;;
    -h|--help)         sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# ------------------------------- Helpers -------------------------------------
info()  { printf '\e[1;34m[INFO]\e[0m %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m %s\n' "$*"; }
die()   { printf '\e[1;31m[FAIL]\e[0m %s\n' "$*" >&2; exit 1; }
step()  { printf '\n\e[1;36m==== %s ====\e[0m\n' "$*"; }
trap 'die "line $LINENO: \"$BASH_COMMAND\" failed (exit $?)"' ERR

# retry <tries> <sleep> cmd...
retry() { local n=$1 s=$2 i; shift 2; for ((i=1;i<=n;i++)); do "$@" && return 0; sleep "$s"; done; return 1; }

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes
          -o ServerAliveInterval=30 -o LogLevel=ERROR)
rssh() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"; }

# Run a bash script (read on stdin) as root on a node; local node = no SSH.
run_root() {
  local ip=$1
  if [[ $ip == "$MASTER_01_IP" ]]; then sudo bash -s; else rssh "$ip" "sudo bash -s"; fi
}

# =============================================================================
# node_prep: phases 1-3 — executed as root on every node (sent through stdin)
# =============================================================================
node_prep() {
  set -Eeuo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local NODE_IP=$1
  local APT=(apt-get -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold)
  log() { printf '[%s] %s\n' "$(hostname)" "$*"; }

  log "Phase 1.1 /etc/hosts"
  sed -i -E '/[[:space:]]k8s-(master|worker)-0[0-9]([[:space:]]|$)/d' /etc/hosts
  printf '%s\n' "${HOSTS_BLOCK}" >> /etc/hosts

  log "Phase 1.2 swap off"
  swapoff -a
  sed -ri '/^[^#].*\sswap\s/s/^/#/' /etc/fstab
  # systemd may still activate swap units (e.g. swap.img / zram) — mask them
  systemctl list-units --type=swap --plain --no-legend 2>/dev/null | awk '{print $1}' \
    | xargs -r systemctl mask --now >/dev/null 2>&1 || true
  [[ $(awk '/^SwapTotal:/ {print $2}' /proc/meminfo) -eq 0 ]] || { log "swap still on"; exit 1; }

  log "Phase 1.3 kernel modules"
  printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
  modprobe overlay
  modprobe br_netfilter

  log "Phase 1.4 sysctl"
  cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null

  log "Phase 2 CRI-O ${CRIO_VERSION} + Phase 3 kubeadm/kubelet/kubectl ${K8S_VERSION}"
  "${APT[@]}" update
  "${APT[@]}" install curl gpg ca-certificates apt-transport-https
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL --retry 5 "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/cri-o.list
  curl -fsSL --retry 5 "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  chmod 644 /etc/apt/keyrings/*.gpg /etc/apt/sources.list.d/{cri-o,kubernetes}.list
  "${APT[@]}" update
  "${APT[@]}" install cri-o cri-tools kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl >/dev/null

  # kubelet must advertise the 10.10.10.x address, not whatever it guesses
  echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet

  systemctl daemon-reload
  systemctl enable --now crio
  systemctl enable kubelet           # starts properly after kubeadm init/join
  systemctl is-active --quiet crio || { log "crio is not active"; exit 1; }

  crictl config --set runtime-endpoint="${CRI_SOCKET}" --set image-endpoint="${CRI_SOCKET}"
  crictl info >/dev/null

  log "DONE: $(crio --version 2>/dev/null | awk 'NR==1 {print "crio "$3}') / kubeadm $(kubeadm version -o short)"
}

# Build the self-contained script sent to a node for phases 1-3
prep_script() {
  local ip=$1
  printf 'K8S_VERSION=%q CRIO_VERSION=%q CRI_SOCKET=%q\n' "$K8S_VERSION" "$CRIO_VERSION" "$CRI_SOCKET"
  printf 'HOSTS_BLOCK=%q\n' "$HOSTS_BLOCK"
  declare -f node_prep
  printf 'node_prep %q\n' "$ip"
}

# =============================================================================
# Pre-flight
# =============================================================================
[[ $EUID -ne 0 ]] || die "Run as the normal user (ubuntu), not root / sudo."
ip -o -4 addr show | grep -qw "$MASTER_01_IP" || die "Run this script on k8s-master-01 (${MASTER_01_IP})."

HOSTS_BLOCK=$(for n in "${NODES[@]}"; do read -r name ip _ <<<"$n"; echo "$ip $name"; done)
LOG_DIR="$HOME/setup-v2-logs"; mkdir -p "$LOG_DIR"

step "Cluster plan"
for n in "${NODES[@]}"; do read -r name ip role <<<"$n"; info "$(printf '%-14s %-12s %s' "$name" "$ip" "$role")"; done
info "K8s ${K8S_VERSION} | CRI-O ${CRIO_VERSION} | Calico ${CALICO_VERSION} | MetalLB ${METALLB_VERSION}"
info "endpoint ${CP_ENDPOINT} | pods ${POD_CIDR} | services ${SERVICE_CIDR} | LB pool ${METALLB_POOL}"
if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "Continue? [y/N] " a; [[ $a =~ ^[Yy]$ ]] || exit 1
fi

step "Pre-flight: sudo, SSH keys, connectivity"
sudo -n true 2>/dev/null || sudo -v || die "sudo required on k8s-master-01"
[[ -f $HOME/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q
for n in "${NODES[@]:1}"; do
  read -r name ip _ <<<"$n"
  if ! rssh "$ip" true 2>/dev/null; then
    info "pushing SSH key to ${name} (${ip}) with password auth"
    command -v sshpass >/dev/null || sudo apt-get install -y -q sshpass >/dev/null
    SSHPASS="$SSH_PASS" sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new \
      -i "$HOME/.ssh/id_ed25519.pub" "${SSH_USER}@${ip}" >/dev/null 2>&1 \
      || die "cannot push SSH key to ${SSH_USER}@${ip} (wrong SSH_PASS?)"
  fi
  if ! rssh "$ip" "sudo -n true" 2>/dev/null; then
    info "enabling passwordless sudo for ${SSH_USER} on ${name}"
    rssh "$ip" "echo $(printf %q "$SSH_PASS") | sudo -S -p '' sh -c \
      'echo \"${SSH_USER} ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/90-${SSH_USER} && chmod 440 /etc/sudoers.d/90-${SSH_USER}'" \
      || die "cannot get sudo on ${name}"
  fi
  ok "${name} (${ip}) SSH + sudo OK"
done
# keep local sudo alive during the whole run
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done ) 2>/dev/null &

# =============================================================================
step "Phases 1-3 on all 5 nodes in parallel (logs: ${LOG_DIR})"
# =============================================================================
declare -A PIDS
for n in "${NODES[@]}"; do
  read -r name ip _ <<<"$n"
  prep_script "$ip" | run_root "$ip" > "${LOG_DIR}/${name}.log" 2>&1 &
  PIDS[$name]=$!
done
FAILED=0
for n in "${NODES[@]}"; do
  read -r name ip _ <<<"$n"
  if wait "${PIDS[$name]}"; then
    ok "$(tail -1 "${LOG_DIR}/${name}.log")"
  else
    warn "${name} failed — last lines of ${LOG_DIR}/${name}.log:"; tail -15 "${LOG_DIR}/${name}.log" | sed 's/^/    /'
    FAILED=1
  fi
done
[[ $FAILED -eq 0 ]] || die "Phases 1-3 failed on at least one node"

# =============================================================================
step "Phase 4: kubeadm init (k8s-master-01)"
# =============================================================================
if sudo test -f /etc/kubernetes/admin.conf; then
  info "control plane already initialised — skipping kubeadm init"
else
  sudo kubeadm config images pull --cri-socket "$CRI_SOCKET" --kubernetes-version "$(kubeadm version -o short)"
  sudo kubeadm init \
    --control-plane-endpoint "$CP_ENDPOINT" \
    --apiserver-advertise-address "$MASTER_01_IP" \
    --pod-network-cidr "$POD_CIDR" \
    --service-cidr "$SERVICE_CIDR" \
    --cri-socket "$CRI_SOCKET" \
    --upload-certs | tee "${LOG_DIR}/kubeadm-init.log"
fi
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
retry 60 5 kubectl get --raw=/readyz >/dev/null 2>&1 || die "API server not ready"
ok "API server ready"

# =============================================================================
step "Phase 5: Calico ${CALICO_VERSION}"
# =============================================================================
CALICO_FILE="$HOME/calico.yaml"
curl -fsSL --retry 5 -o "$CALICO_FILE" \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
# Uncomment CALICO_IPV4POOL_CIDR and set it to POD_CIDR (whatever the indentation)
sed -i -E \
  -e 's|^([[:space:]]*)#[[:space:]]*(- name: CALICO_IPV4POOL_CIDR)[[:space:]]*$|\1\2|' \
  -e "/^[[:space:]]*- name: CALICO_IPV4POOL_CIDR/{n;s|^([[:space:]]*)#[[:space:]]*value:.*|\1  value: \"${POD_CIDR}\"|}" \
  "$CALICO_FILE"
grep -A1 -E '^[[:space:]]*- name: CALICO_IPV4POOL_CIDR' "$CALICO_FILE" | grep -q "\"${POD_CIDR}\"" \
  || die "could not set CALICO_IPV4POOL_CIDR in $CALICO_FILE"
kubectl apply --server-side --force-conflicts -f "$CALICO_FILE" >/dev/null
# Pin node IP detection to the cluster subnet (avoids picking a wrong interface)
kubectl -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD="cidr=${NODE_SUBNET}" >/dev/null
kubectl -n kube-system rollout status ds/calico-node --timeout=600s
kubectl wait --for=condition=Ready node/k8s-master-01 --timeout=300s
ok "Calico running, k8s-master-01 Ready"

# =============================================================================
step "Phase 6: join k8s-master-02 / k8s-master-03 (control plane)"
# =============================================================================
JOIN_CMD=$(sudo kubeadm token create --print-join-command --ttl 2h)
CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
[[ $CERT_KEY =~ ^[0-9a-f]{64}$ ]] || die "could not get certificate key (got: $CERT_KEY)"

for n in "${NODES[@]:1}"; do
  read -r name ip role <<<"$n"
  [[ $role == master ]] || continue
  if rssh "$ip" "sudo test -f /etc/kubernetes/kubelet.conf"; then
    info "${name} already joined — skipping"
  else
    info "joining ${name} (${ip}) as control plane ..."
    rssh "$ip" "sudo ${JOIN_CMD} --control-plane --certificate-key ${CERT_KEY} \
                --apiserver-advertise-address ${ip} --cri-socket ${CRI_SOCKET}" \
      > "${LOG_DIR}/${name}-join.log" 2>&1 \
      || { tail -25 "${LOG_DIR}/${name}-join.log"; die "join failed on ${name}"; }
  fi
  rssh "$ip" 'mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config && chmod 600 ~/.kube/config'
  kubectl wait --for=condition=Ready "node/${name}" --timeout=600s >/dev/null
  ok "${name} joined and Ready"
done

info "etcd members:"
kubectl -n kube-system exec etcd-k8s-master-01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  --endpoints="https://${MASTER_01_IP}:2379,https://${MASTER_02_IP}:2379,https://${MASTER_03_IP}:2379" \
  endpoint health 2>&1 | sed 's/^/    /' || warn "etcd health check failed"

# =============================================================================
step "Phase 7: join workers"
# =============================================================================
declare -A JPIDS
for n in "${NODES[@]}"; do
  read -r name ip role <<<"$n"
  [[ $role == worker ]] || continue
  if rssh "$ip" "sudo test -f /etc/kubernetes/kubelet.conf"; then
    info "${name} already joined — skipping"; continue
  fi
  info "joining ${name} (${ip}) ..."
  rssh "$ip" "sudo ${JOIN_CMD} --cri-socket ${CRI_SOCKET}" > "${LOG_DIR}/${name}-join.log" 2>&1 &
  JPIDS[$name]=$!
done
for name in "${!JPIDS[@]}"; do
  wait "${JPIDS[$name]}" || { tail -25 "${LOG_DIR}/${name}-join.log"; die "join failed on ${name}"; }
done
for n in "${NODES[@]}"; do
  read -r name ip role <<<"$n"
  [[ $role == worker ]] || continue
  kubectl label node "$name" node-role.kubernetes.io/worker= --overwrite >/dev/null
  kubectl wait --for=condition=Ready "node/${name}" --timeout=600s >/dev/null
  ok "${name} joined, labelled worker, Ready"
done
kubectl get nodes -o wide

# =============================================================================
step "Phase 8: MetalLB ${METALLB_VERSION}"
# =============================================================================
# strictARP (recommended by MetalLB for L2 mode)
kubectl -n kube-system get cm kube-proxy -o yaml | sed 's/strictARP: false/strictARP: true/' \
  | kubectl apply -f - >/dev/null 2>&1 && kubectl -n kube-system rollout restart ds/kube-proxy >/dev/null
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" >/dev/null
kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null
kubectl -n metallb-system rollout status deploy/controller --timeout=300s
kubectl -n metallb-system rollout status ds/speaker --timeout=300s
# The validating webhook needs a few seconds after the controller is Ready
retry 30 5 kubectl apply -f - >/dev/null 2>&1 <<EOF || die "could not create MetalLB pool"
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
kubectl get ipaddresspool,l2advertisement -n metallb-system
ok "MetalLB ready"

# =============================================================================
HEADLAMP_PORT=""; TOKEN_FILE="$HOME/headlamp-admin-token.txt"
if [[ $HEADLAMP -eq 1 ]]; then
step "Phase 9: Helm + Headlamp"
# =============================================================================
if ! command -v helm >/dev/null; then
  curl -fsSL --retry 5 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ --force-update >/dev/null
helm repo update >/dev/null
HL_ARGS=(); [[ -n $HEADLAMP_CHART_VERSION ]] && HL_ARGS=(--version "$HEADLAMP_CHART_VERSION")
helm upgrade --install headlamp headlamp/headlamp -n headlamp --create-namespace \
  --set service.type=NodePort "${HL_ARGS[@]}" --wait --timeout 10m >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp-admin
  namespace: headlamp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin-user        # "headlamp-admin" is already used by the chart
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: headlamp-admin
  namespace: headlamp
EOF
( umask 077; kubectl create token headlamp-admin -n headlamp --duration=8760h > "$TOKEN_FILE" )
HEADLAMP_PORT=$(kubectl -n headlamp get svc headlamp -o jsonpath='{.spec.ports[0].nodePort}')
ok "Headlamp on NodePort ${HEADLAMP_PORT}, token in ${TOKEN_FILE}"
fi

# =============================================================================
if [[ $SMOKE_TEST -eq 1 ]]; then
step "Phase 10: smoke test"
# =============================================================================
SMOKE_OK=1
kubectl create deployment apache --image=httpd:latest --replicas=2 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl rollout status deploy/apache --timeout=300s
kubectl get svc apache >/dev/null 2>&1 || kubectl expose deployment apache --port=80 --type=NodePort >/dev/null
kubectl get svc apache-lb >/dev/null 2>&1 || kubectl expose deployment apache --name=apache-lb --port=80 --type=LoadBalancer >/dev/null
kubectl get pods -l app=apache -o wide
NP=$(kubectl get svc apache -o jsonpath='{.spec.ports[0].nodePort}')
for ip in "$WORKER_01_IP" "$WORKER_02_IP" "$MASTER_01_IP"; do
  if retry 12 5 curl -sf -o /dev/null "http://${ip}:${NP}"; then ok "NodePort http://${ip}:${NP}"; else warn "NodePort http://${ip}:${NP} FAILED"; SMOKE_OK=0; fi
done
LB_IP=""
for _ in $(seq 30); do LB_IP=$(kubectl get svc apache-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); [[ -n $LB_IP ]] && break; sleep 2; done
if [[ -n $LB_IP ]] && retry 12 5 curl -sf -o /dev/null "http://${LB_IP}"; then ok "LoadBalancer http://${LB_IP}"; else warn "LoadBalancer FAILED (ip='${LB_IP}')"; SMOKE_OK=0; fi
if kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i --quiet -- \
     nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then ok "CoreDNS OK"; else warn "DNS test FAILED"; SMOKE_OK=0; fi
kubectl delete svc apache apache-lb --ignore-not-found >/dev/null
kubectl delete deployment apache --ignore-not-found --wait >/dev/null
kubectl wait --for=delete pod -l app=apache --timeout=120s >/dev/null 2>&1 || true
[[ $SMOKE_OK -eq 1 ]] && ok "smoke test passed" || warn "smoke test had failures"
fi

# =============================================================================
step "Final checklist"
# =============================================================================
kubectl get nodes -o wide
kubectl get pods -A -o wide | grep -vE 'Running|Completed' | sed '1!s/^/  NOT RUNNING: /' || true
READY=$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l)
CAL=$(kubectl -n kube-system get ds calico-node -o jsonpath='{.status.numberReady}')
SPK=$(kubectl -n metallb-system get ds speaker -o jsonpath='{.status.numberReady}')
[[ $READY -eq 5 ]] && ok "5/5 nodes Ready" || warn "${READY}/5 nodes Ready"
[[ $CAL -eq 5 ]]   && ok "calico-node 5/5"  || warn "calico-node ${CAL}/5"
[[ $SPK -eq 5 ]]   && ok "metallb speaker 5/5" || warn "metallb speaker ${SPK}/5"
echo
[[ -n $HEADLAMP_PORT ]] && info "Headlamp : http://${MASTER_01_IP}:${HEADLAMP_PORT}   token: cat ${TOKEN_FILE}"
ok "Cluster setup finished."
