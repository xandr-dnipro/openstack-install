#!/bin/bash

# OpenStack-Helm AIO Deployment Script for Ubuntu 22.04
# Scope: AIO + MetalLB + Neutron OVN
# Hardened: kubeadm via pkgs.k8s.io if available, else MicroK8s 1.30 fallback.
# Non-interactive gpg, sysctl noise silenced, pause:3.9, crictl endpoint, API readiness,
# hostname/IP pin, UFW off, MetalLB webhook readiness, no deprecated 'make all'.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ----------------------
# VARS
# ----------------------
POD_CIDR="10.244.0.0/16"
OSH_INFRA_REPO="https://opendev.org/openstack/openstack-helm-infra"
OSH_REPO="https://opendev.org/openstack/openstack-helm"
METALLB_RANGE="${METALLB_RANGE:-192.168.0.240-192.168.0.250}"  # override via env
HOSTNAME_FQDN="${HOSTNAME_FQDN:-openstack}"
KEYRING_NEW="/etc/apt/keyrings/kubernetes-apt.gpg"
KUBE_LIST="/etc/apt/sources.list.d/kubernetes.list"
MODE="kubeadm"  # will flip to microk8s if pkgs.k8s.io unreachable
K8S_TRACK="v1.30"  # stable track

# ----------------------
# PREREQS
# ----------------------
apt update -y >/dev/null || true
apt upgrade -y >/dev/null || true
apt install -y curl wget gnupg gpg lsb-release apt-transport-https ca-certificates git jq make python3-pip nfs-common iproute2 ufw >/dev/null

# Disable swap for kubelet
swapoff -a || true
sed -i '/ swap / s/^/#/' /etc/fstab || true

# Kernel params
modprobe overlay || true
modprobe br_netfilter || true
cat >/etc/modules-load.d/k8s.conf <<EOF_CONF
overlay
br_netfilter
EOF_CONF
cat >/etc/sysctl.d/k8s.conf <<EOF_SYSCTL
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF_SYSCTL
# Silence noisy sysctl output; non-fatal on some VM kernels
sysctl --system >/dev/null 2>&1 || true

# Ensure hostname resolves to node IP
NODE_ROUTE=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
NODE_IP=$(echo "$NODE_ROUTE" | awk '{print $7; exit}')
NODE_DEV=$(echo "$NODE_ROUTE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
if [[ -z "${NODE_IP:-}" ]]; then
  NODE_IP=$(hostname -I | awk '{print $1}')
fi
if [[ -z "${NODE_DEV:-}" && -n "${NODE_IP:-}" ]]; then
  NODE_DEV=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ ip"/" {print $2; exit}')
fi
if [[ -n "${NODE_IP:-}" ]]; then
  if ! grep -q "^${NODE_IP}\\s\+${HOSTNAME_FQDN}\\b" /etc/hosts; then
    sed -i "/\\b${HOSTNAME_FQDN}\\b/d" /etc/hosts
    echo "${NODE_IP} ${HOSTNAME_FQDN}" >> /etc/hosts
  fi
fi

# Disable UFW for AIO simplicity
ufw status | grep -q inactive || ufw disable || true

# Attempt to capture host network CIDR for MetalLB sanity checks
NODE_CIDR=""
if [[ -n "${NODE_DEV:-}" ]]; then
  NODE_CIDR=$(ip -o -4 addr show "$NODE_DEV" | awk 'NR==1 {print $4}')
fi
export NODE_CIDR METALLB_RANGE
if [[ -n "${NODE_CIDR:-}" && -n "${METALLB_RANGE:-}" ]]; then
  python3 - <<'PY'
import ipaddress
import os
import sys

cidr = os.environ.get("NODE_CIDR")
range_spec = os.environ.get("METALLB_RANGE")
if not cidr or not range_spec:
    sys.exit(0)
segment = range_spec.split(",")[0].strip()
if not segment:
    sys.exit(0)
if "-" in segment:
    start, end = [item.strip() for item in segment.split("-", 1)]
else:
    start = segment.strip()
    end = segment.strip()
try:
    network = ipaddress.ip_network(cidr, strict=False)
    start_ip = ipaddress.ip_address(start)
    end_ip = ipaddress.ip_address(end)
    if start_ip not in network or end_ip not in network:
        print(
            f"[WARN] METALLB_RANGE '{range_spec}' is outside host network {cidr}. "
            "Update METALLB_RANGE for your environment.",
            file=sys.stderr,
        )
except ValueError:
    print(
        f"[WARN] Unable to validate METALLB_RANGE '{range_spec}'. "
        "Ensure it matches the management network.",
        file=sys.stderr,
    )
PY
fi

# ----------------------
# CONTAINERD + CRICTL
# ----------------------
apt install -y containerd >/dev/null
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
# systemd cgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# pin sandbox_image to pause:3.9
sed -i 's#sandbox_image = ".*"#sandbox_image = "registry.k8s.io/pause:3.9"#' /etc/containerd/config.toml
# crictl points to containerd to silence warnings
cat >/etc/crictl.yaml <<'EOF_CRI'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF_CRI
systemctl enable containerd >/dev/null
systemctl restart containerd >/dev/null

# ----------------------
# TRY KUBEADM PATH (pkgs.k8s.io)
# ----------------------
mkdir -p /etc/apt/keyrings
rm -f "$KEYRING_NEW" "$KUBE_LIST"
if curl -fsSI "https://pkgs.k8s.io/core:/stable:/${K8S_TRACK#v}/deb/Release" >/dev/null; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_TRACK#v}/deb/Release.key" \
    | gpg --dearmor --yes -o "$KEYRING_NEW"
  chmod 0644 "$KEYRING_NEW"
  echo "deb [signed-by=$KEYRING_NEW] https://pkgs.k8s.io/core:/stable:/${K8S_TRACK#v}/deb/ /" > "$KUBE_LIST"
  apt update -y >/dev/null || true
  if apt-get install -y kubelet kubeadm kubectl >/dev/null 2>&1; then
    apt-mark hold kubelet kubeadm kubectl >/dev/null || true
    MODE="kubeadm"
  else
    MODE="microk8s"
  fi
else
  MODE="microk8s"
fi

# ----------------------
# MICROK8S FALLBACK
# ----------------------
if [[ "$MODE" == "microk8s" ]]; then
  apt install -y snapd >/dev/null
  if ! snap list microk8s >/dev/null 2>&1; then
    snap install microk8s --channel=1.30/stable --classic
  fi
  microk8s status --wait-ready
  microk8s enable dns
  microk8s enable metallb:"${METALLB_RANGE}"
  # kubectl wrapper so the rest of the script can call kubectl
  cat >/usr/local/bin/kubectl <<'EOK'
#!/bin/bash
exec microk8s kubectl "$@"
EOK
  chmod +x /usr/local/bin/kubectl
  # KUBECONFIG export
  mkdir -p "$HOME/.kube"
  microk8s config > "$HOME/.kube/config"
  chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
  export KUBECONFIG="$HOME/.kube/config"
fi

# ----------------------
# KUBEADM INIT (only in kubeadm mode)
# ----------------------
if [[ "$MODE" == "kubeadm" ]]; then
  kubeadm init \
    --apiserver-advertise-address="${NODE_IP:-0.0.0.0}" \
    --pod-network-cidr="${POD_CIDR}"
  mkdir -p "$HOME/.kube"
  cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
  export KUBECONFIG="$HOME/.kube/config"
  grep -q "KUBECONFIG" "$HOME/.bashrc" || echo "export KUBECONFIG=\$HOME/.kube/config" >> "$HOME/.bashrc"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
  # Calico for kubeadm path
  curl -L --retry 5 --retry-delay 2 --retry-all-errors -o calico.yaml \
    https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/calico.yaml
  kubectl apply --validate=false -f calico.yaml
fi

# ----------------------
# WAIT FOR CLUSTER READY
# ----------------------
for _ in {1..60}; do kubectl get nodes >/dev/null 2>&1 && break; sleep 2; done
kubectl wait --for=condition=Ready node --all --timeout=600s || true

# ----------------------
# HELM + OSH PLUGIN
# ----------------------
curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
helm plugin install https://opendev.org/openstack/openstack-helm-plugin >/dev/null || true

# ----------------------
# CLONE REPOS
# ----------------------
cd /opt
[ -d openstack-helm-infra ] || git clone ${OSH_INFRA_REPO}
[ -d openstack-helm ] || git clone ${OSH_REPO}

# ----------------------
# METALLB READY + ADDRESSPOOL (robust for kubeadm and microk8s)
# ----------------------
if [[ "$MODE" == "kubeadm" ]]; then
  helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace >/dev/null 2>&1
fi
# Wait for controller and webhook to be ready to avoid InternalError on CRDs
kubectl -n metallb-system rollout status deploy/controller --timeout=600s || true
# Wait for webhook service endpoints
for _ in {1..60}; do
  if kubectl -n metallb-system get endpoints webhook-service -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done
# Create pool only if not exists
if ! kubectl -n metallb-system get ipaddresspool public-pool >/dev/null 2>&1; then
cat <<EOF_POOL | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: public-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: public-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - public-pool
EOF_POOL
fi

# ----------------------
# OSH-INFRA (no 'make all')
# ----------------------
cd /opt/openstack-helm-infra
./tools/deployment/component/ingress.sh
./tools/deployment/component/ceph.sh
./tools/deployment/component/databases.sh
./tools/deployment/component/rabbitmq.sh
./tools/deployment/component/memcached.sh
./tools/deployment/component/keystone.sh
# OVN central if available in repo
if [[ -f ./tools/deployment/component/ovn.sh ]]; then
  ./tools/deployment/component/ovn.sh
fi

# Ensure ingress services are LoadBalancer to get MetalLB IPs
for ns in ingress-nginx ingress kube-system osh-infra openstack; do
  kubectl -n "$ns" get svc >/dev/null 2>&1 || continue
  while read -r svc; do
    [[ -z "$svc" ]] && continue
    if echo "$svc" | grep -qiE 'ingress|nginx'; then
      kubectl -n "$ns" patch svc "$svc" -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null 2>&1 || true
    fi
  done < <(kubectl -n "$ns" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
done

# ----------------------
# OPENSTACK SERVICES (OVN first preference) (no 'make all')
# ----------------------
cd /opt/openstack-helm
./tools/deployment/component/glance.sh
./tools/deployment/component/nova.sh
if [[ -f ./tools/deployment/component/neutron-ovn.sh ]]; then
  ./tools/deployment/component/neutron-ovn.sh
else
  ./tools/deployment/component/neutron.sh
fi
./tools/deployment/component/horizon.sh
./tools/deployment/component/cinder.sh

# ----------------------
# VERIFY (concise)
# ----------------------
kubectl get nodes -o wide
kubectl get pods -A
helm list -A
kubectl get svc -A | awk 'NR==1 || $5=="LoadBalancer" {print $0}'

printf "\nMode: %s\n" "$MODE"
echo "Done"
