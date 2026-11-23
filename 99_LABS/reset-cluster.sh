#!/usr/bin/env bash
#
# USAGE
#   Reset THIS node only:
#     sudo ./reset-cluster.sh            # asks for confirmation
#     sudo ./reset-cluster.sh -y         # no confirmation
#
#   Reset ALL 5 nodes from one machine (needs SSH + passwordless sudo):
#     ./reset-cluster.sh --all-nodes [-y] [--ssh-user ubuntu]
#     Workers are reset first, then masters.
#
# OPTIONS
#   -y, --yes          Do not ask for confirmation
#   --keep-swap-off    Do not re-enable swap in /etc/fstab
#   --keep-hosts       Do not remove the k8s-* entries from /etc/hosts
#   --no-reboot        Do not offer/perform a reboot at the end
#   --reboot           Reboot automatically at the end (recommended)
#   --all-nodes        Run this script on every node listed below via SSH
#   --ssh-user USER    SSH user for --all-nodes (default: current user)
# =============================================================================
set -uo pipefail
ORIG_ARGS=("$@")

# ---- Inventory (same as 00_setup-cluster.md, Section 0) --------------------
MASTER_01_IP="${MASTER_01_IP:-10.10.10.11}"
MASTER_02_IP="${MASTER_02_IP:-10.10.10.12}"
MASTER_03_IP="${MASTER_03_IP:-10.10.10.13}"
WORKER_01_IP="${WORKER_01_IP:-10.10.10.21}"
WORKER_02_IP="${WORKER_02_IP:-10.10.10.22}"
CRI_SOCKET="${CRI_SOCKET:-unix:///var/run/crio/crio.sock}"

ASSUME_YES=0
KEEP_SWAP_OFF=0
KEEP_HOSTS=0
REBOOT_MODE="ask"   # ask | yes | no
ALL_NODES=0
SSH_USER="${USER:-$(id -un)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)        ASSUME_YES=1 ;;
    --keep-swap-off) KEEP_SWAP_OFF=1 ;;
    --keep-hosts)    KEEP_HOSTS=1 ;;
    --reboot)        REBOOT_MODE="yes" ;;
    --no-reboot)     REBOOT_MODE="no" ;;
    --all-nodes)     ALL_NODES=1 ;;
    --ssh-user)      SSH_USER="$2"; shift ;;
    -h|--help)       sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

c_info()  { printf '\e[1;34m[INFO]\e[0m  %s\n' "$*"; }
c_ok()    { printf '\e[1;32m[ OK ]\e[0m  %s\n' "$*"; }
c_warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
step()    { printf '\n\e[1;36m==> %s\e[0m\n' "$*"; }
have()    { command -v "$1" >/dev/null 2>&1; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  echo
  c_warn "$1"
  read -r -p "Type 'yes' to continue: " ans
  [[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
}

# =============================================================================
# Mode 1: orchestrate all nodes over SSH
# =============================================================================
if [[ $ALL_NODES -eq 1 ]]; then
  NODES=("$WORKER_01_IP" "$WORKER_02_IP" "$MASTER_03_IP" "$MASTER_02_IP" "$MASTER_01_IP")
  [[ $EUID -eq 0 ]] && c_warn "--all-nodes runs SSH as ${SSH_USER}; you do not need sudo locally."
  confirm "This will WIPE Kubernetes from ALL nodes: ${NODES[*]}"

  FWD_ARGS=(-y)
  [[ $KEEP_SWAP_OFF -eq 1 ]] && FWD_ARGS+=(--keep-swap-off)
  [[ $KEEP_HOSTS    -eq 1 ]] && FWD_ARGS+=(--keep-hosts)
  # Never reboot the remote nodes while we are still talking to the others
  # unless explicitly asked; default for remote mode is no reboot prompt.
  if [[ $REBOOT_MODE == "yes" ]]; then FWD_ARGS+=(--reboot); else FWD_ARGS+=(--no-reboot); fi

  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  FAILED=()
  for ip in "${NODES[@]}"; do
    step "Resetting node ${ip}"
    if scp "${SSH_OPTS[@]}" "$0" "${SSH_USER}@${ip}:/tmp/reset-cluster.sh" \
       && ssh -t "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "sudo bash /tmp/reset-cluster.sh ${FWD_ARGS[*]}; rm -f /tmp/reset-cluster.sh"; then
      c_ok "${ip} reset"
    else
      c_warn "${ip} FAILED (or reboot dropped the session)"
      FAILED+=("$ip")
    fi
  done
  echo
  [[ ${#FAILED[@]} -eq 0 ]] && c_ok "All nodes reset." || c_warn "Check these nodes: ${FAILED[*]}"
  [[ $REBOOT_MODE != "yes" ]] && c_info "Reboot every node to finish: kernel modules/routes are only fully gone after a reboot."
  exit 0
fi

# =============================================================================
# Mode 2: reset THIS node
# =============================================================================
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
fi

confirm "This will completely remove Kubernetes, CRI-O, Calico, MetalLB and Helm from $(hostname)."

export DEBIAN_FRONTEND=noninteractive

# Home dirs whose ~/.kube and helm config must go (root + the sudo caller + all /home users)
HOMES=(/root)
for d in /home/*; do [[ -d "$d" ]] && HOMES+=("$d"); done

# -----------------------------------------------------------------------------
step "1/9  kubeadm reset (tears down control-plane / kubelet / etcd member)"
# -----------------------------------------------------------------------------
if have kubeadm; then
  kubeadm reset -f --cri-socket "${CRI_SOCKET}" 2>&1 | sed 's/^/    /' || c_warn "kubeadm reset returned an error (continuing)"
else
  c_info "kubeadm not installed, skipping"
fi

# -----------------------------------------------------------------------------
step "2/9  Stop services and wipe all CRI-O pods / containers / images"
# -----------------------------------------------------------------------------
systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true
if have crictl && systemctl is-active --quiet crio; then
  crictl --runtime-endpoint "${CRI_SOCKET}" stopp $(crictl --runtime-endpoint "${CRI_SOCKET}" pods -q 2>/dev/null) >/dev/null 2>&1 || true
  crictl --runtime-endpoint "${CRI_SOCKET}" rmp -fa  >/dev/null 2>&1 || true
  crictl --runtime-endpoint "${CRI_SOCKET}" rm  -fa  >/dev/null 2>&1 || true
  crictl --runtime-endpoint "${CRI_SOCKET}" rmi -a   >/dev/null 2>&1 || true
  c_ok "CRI-O pods, containers and images removed"
fi
systemctl stop crio 2>/dev/null || true
systemctl disable crio 2>/dev/null || true

# Unmount anything kubelet / CRI-O left mounted (otherwise rm -rf fails)
for mp in $(awk '$2 ~ "^/(var/lib/kubelet|var/lib/containers|run/containers|var/run/containers|run/netns|var/run/netns)" {print $2}' /proc/mounts | sort -r); do
  umount -l "$mp" 2>/dev/null || true
done

# -----------------------------------------------------------------------------
step "3/9  Purge packages (kubelet, kubeadm, kubectl, cri-o, cri-tools, CNI)"
# -----------------------------------------------------------------------------
# Every .deb related to K8s / container runtimes, whatever repo it came from
# (also catches containerd left over from the original containerd-based install).
PKG_REGEX='^(kube|kubernetes-cni|cri-o|cri-tools|conmon|containerd|runc$|crun$|helm$|calico)'
mapfile -t INSTALLED < <(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 2>/dev/null \
                          | awk '$2 ~ /^[ihr]/ {print $1}' | sed 's/:.*//' | grep -E "$PKG_REGEX" | sort -u)
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
  # Wait for unattended-upgrades / another apt to release the dpkg lock
  for _ in $(seq 1 60); do
    fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || break
    c_info "waiting for dpkg lock..."; sleep 5
  done
  apt-mark unhold "${INSTALLED[@]}" >/dev/null 2>&1 || true
  if apt-get purge -y --allow-change-held-packages "${INSTALLED[@]}"; then
    c_ok "Purged: ${INSTALLED[*]}"
  else
    c_warn "apt purge failed, forcing with dpkg"
    dpkg --purge --force-all "${INSTALLED[@]}" || c_warn "dpkg purge failed too"
  fi
  apt-get autoremove -y --purge
else
  c_info "No Kubernetes / CRI-O / containerd .deb packages installed"
fi

# Snap installs (snap install kubectl --classic, microk8s, helm...)
if have snap; then
  for s in kubectl kubeadm kubelet kube-apiserver helm microk8s k8s k9s kubectx; do
    snap list "$s" >/dev/null 2>&1 && { snap remove --purge "$s" && c_ok "snap removed: $s"; }
  done
fi

# Binaries installed by hand (curl -LO ...; install kubectl /usr/local/bin) in any common location
BINS=(kubectl kubeadm kubelet crictl critest crio conmon helm calicoctl kubectl-calico etcdctl etcdutl
      kubectx kubens k9s kustomize stern kubeconform kubectl-krew)
BIN_DIRS=(/usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /opt/bin /opt/cni/bin /snap/bin)
for h in "${HOMES[@]}"; do BIN_DIRS+=("$h/.local/bin" "$h/bin" "$h/go/bin"); done
for dir in "${BIN_DIRS[@]}"; do
  for b in "${BINS[@]}"; do
    f="$dir/$b"
    [[ -e "$f" || -L "$f" ]] || continue
    # Leave files that still belong to a (non-K8s) .deb alone
    if dpkg -S "$f" >/dev/null 2>&1; then c_warn "$f is owned by a package: $(dpkg -S "$f" | cut -d: -f1)"; continue; fi
    rm -f "$f" && c_ok "removed binary: $f"
  done
done
rm -rf /opt/containerd /etc/containerd /var/lib/containerd /run/containerd
hash -r 2>/dev/null || true

# -----------------------------------------------------------------------------
step "4/9  Remove apt repositories and signing keys"
# -----------------------------------------------------------------------------
rm -f /etc/apt/sources.list.d/kubernetes.list \
      /etc/apt/sources.list.d/cri-o.list \
      /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
      /etc/apt/keyrings/cri-o-apt-keyring.gpg
apt-get update -qq || c_warn "apt-get update failed (network?)"
c_ok "Repos removed"

# -----------------------------------------------------------------------------
step "5/9  Delete Kubernetes / CRI-O / CNI / Calico / etcd files"
# -----------------------------------------------------------------------------
DIRS=(
  /etc/kubernetes /var/lib/kubelet /var/lib/kubeadm /var/lib/etcd /var/log/pods /var/log/containers
  /etc/cni /opt/cni /var/lib/cni /run/cni
  /var/lib/calico /var/run/calico /run/calico /var/log/calico /etc/calico
  /etc/crio /var/lib/crio /run/crio /var/run/crio /var/log/crio
  /var/lib/containers /run/containers /var/run/containers
  /etc/crictl.yaml
  /etc/systemd/system/kubelet.service.d /etc/systemd/system/kubelet.service
  /etc/systemd/system/crio.service.d
  /etc/default/kubelet /etc/sysconfig/kubelet
  /usr/local/bin/helm /usr/local/bin/calicoctl /usr/local/bin/etcdctl
)
for d in "${DIRS[@]}"; do rm -rf "$d"; done

# /etc/containers is shared with podman/buildah — only remove it if neither is installed
if ! have podman && ! have buildah && ! have skopeo; then
  rm -rf /etc/containers
fi

# kubeconfigs + helm config/caches for every user
for h in "${HOMES[@]}"; do
  rm -rf "$h/.kube" "$h/.krew" "$h/.cache/helm" "$h/.config/helm" "$h/.local/share/helm" \
         "$h/.config/k9s" "$h/.local/share/k9s" "$h/calico.yaml" "$h/.helm"
  # Shell aliases / completions / KUBECONFIG exports added during the labs
  for rc in "$h/.bashrc" "$h/.zshrc" "$h/.profile" "$h/.bash_aliases"; do
    [[ -f "$rc" ]] || continue
    if grep -qE 'kubectl|kubeadm|crictl|helm |helm completion|KUBECONFIG|alias k=|complete .* k$|__start_kubectl' "$rc"; then
      cp -a "$rc" "$rc.bak.$(date +%Y%m%d%H%M%S)"
      sed -i -E '/kubectl|kubeadm|crictl|helm completion|KUBECONFIG|alias k=|complete .* k$|__start_kubectl/d' "$rc"
      c_ok "cleaned K8s lines from $rc (backup kept)"
    fi
  done
done
rm -f /etc/bash_completion.d/{kubectl,kubeadm,crictl,helm,k9s} \
      /usr/share/bash-completion/completions/{kubectl,kubeadm,crictl,helm} \
      /usr/share/zsh/vendor-completions/_{kubectl,kubeadm,helm} \
      /etc/profile.d/kube*.sh

# leftover network namespaces created by CRI-O
for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do ip netns delete "$ns" 2>/dev/null || true; done

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
c_ok "Files removed"

# -----------------------------------------------------------------------------
step "6/9  Clean network: Calico interfaces, IPVS, iptables (v4 + v6)"
# -----------------------------------------------------------------------------
for l in $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 \
           | grep -E '^(cali|tunl0|vxlan\.calico|vxlan-v6\.calico|kube-ipvs0|cni0|flannel|nodelocaldns|veth)'); do
  ip link delete "$l" 2>/dev/null || true
done
have ipvsadm && ipvsadm --clear 2>/dev/null || true

# Set ACCEPT policies FIRST so we never lock ourselves out of SSH, then flush.
for ipt in iptables ip6tables iptables-legacy ip6tables-legacy; do
  have "$ipt" || continue
  for chain in INPUT FORWARD OUTPUT; do "$ipt" -P "$chain" ACCEPT 2>/dev/null || true; done
  for table in filter nat mangle raw; do
    "$ipt" -t "$table" -F 2>/dev/null || true
    "$ipt" -t "$table" -X 2>/dev/null || true
  done
done
# Calico / kube-proxy can also leave nftables tables behind
if have nft; then
  for t in $(nft list tables 2>/dev/null | awk '/calico|kube|cali/ {print $2" "$3}' | tr ' ' ':'); do
    nft delete table "${t%%:*}" "${t#*:}" 2>/dev/null || true
  done
fi
# Restart UFW (if used) so its own rules come back after the flush
if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw reload >/dev/null 2>&1 || true
fi
c_ok "Network cleaned"

# -----------------------------------------------------------------------------
step "7/9  Undo Phase 1.3/1.4: kernel modules + sysctl"
# -----------------------------------------------------------------------------
rm -f /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf
sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
modprobe -r ipip     2>/dev/null || true   # Calico IPIP
modprobe -r br_netfilter 2>/dev/null || true
modprobe -r overlay  2>/dev/null || true   # may stay loaded if something else uses it
sysctl --system >/dev/null 2>&1 || true
c_ok "Modules/sysctl config removed (reboot guarantees defaults)"

# -----------------------------------------------------------------------------
step "8/9  Undo Phase 1.1/1.2: /etc/hosts entries + swap"
# -----------------------------------------------------------------------------
if [[ $KEEP_HOSTS -eq 0 ]]; then
  cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
  sed -i -E '/[[:space:]]k8s-(master|worker)-0[0-9]([[:space:]]|$)/d' /etc/hosts
  c_ok "k8s-* entries removed from /etc/hosts (backup saved next to it)"
else
  c_info "Keeping /etc/hosts entries (--keep-hosts)"
fi

if [[ $KEEP_SWAP_OFF -eq 0 ]]; then
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  # Reverse of: sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
  sed -ri '/^#+[^#]*\sswap\s/s/^#+//' /etc/fstab
  swapon -a 2>/dev/null || true
  c_ok "Swap re-enabled in /etc/fstab (backup saved next to it)"
else
  c_info "Leaving swap disabled (--keep-swap-off)"
fi

# -----------------------------------------------------------------------------
step "9/9  Verification"
# -----------------------------------------------------------------------------
LEFT=0
hash -r 2>/dev/null || true
SEARCH_PATH="$PATH:/snap/bin:/usr/local/bin:/opt/bin"
for h in "${HOMES[@]}"; do SEARCH_PATH+=":$h/.local/bin:$h/bin:$h/go/bin"; done
for b in kubeadm kubelet kubectl crio crictl helm containerd ctr; do
  found=$(PATH="$SEARCH_PATH" type -ap "$b" 2>/dev/null | sort -u)
  [[ -n "$found" ]] && { c_warn "binary still present: $(echo $found)"; LEFT=1; }
done
left_pkgs=$(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 2>/dev/null | awk '$2 ~ /^[ihr]/ {print $1}' | grep -E "$PKG_REGEX")
[[ -n "$left_pkgs" ]] && { c_warn "packages still installed: $(echo $left_pkgs)"; LEFT=1; }
for d in /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni /var/lib/containers /etc/crio /var/lib/containerd; do
  [[ -e "$d" ]] && { c_warn "still exists: $d"; LEFT=1; }
done
ip -o link show | grep -qE 'cali|tunl0|vxlan\.calico' && { c_warn "Calico interfaces still present (reboot will clear them)"; LEFT=1; }
ss -ltn 2>/dev/null | grep -qE ':(6443|2379|2380|10250)\b' && { c_warn "a K8s port is still listening"; LEFT=1; }
[[ $LEFT -eq 0 ]] && c_ok "$(hostname) is clean: no Kubernetes, CRI-O, Calico or Helm left."

echo
case "$REBOOT_MODE" in
  yes) c_info "Rebooting in 5s..."; sleep 5; systemctl reboot ;;
  no)  c_info "Done. A reboot is recommended to fully clear kernel modules and routes." ;;
  ask)
    if [[ $ASSUME_YES -eq 0 ]]; then
      read -r -p "Reboot now? [y/N] " r
      [[ "$r" =~ ^[Yy]$ ]] && systemctl reboot
    else
      c_info "Done. A reboot is recommended."
    fi ;;
esac
