#!/bin/bash

# OpenStack-Helm AIO Deployment Script for Ubuntu 22.04
# Purpose: Deploy full OpenStack cloud on Kubernetes using OpenStack-Helm
# Scope: AIO, MetalLB for external IP, Neutron with OVN backend
# Tested on: Ubuntu 22.04 LTS

set -euo pipefail

# ----------------------
# VARIABLES
# ----------------------
K8S_VERSION="1.30.4-1.1"
POD_CIDR="10.244.0.0/16"
OSH_INFRA_REPO="https://opendev.org/openstack/openstack-helm-infra"
OSH_REPO="https://opendev.org/openstack/openstack-helm"
METALLB_RANGE="${METALLB_RANGE:-10.0.0.200-10.0.0.240}"

# ----------------------
# STEP 1. SYSTEM PREP
# ----------------------
apt update && apt upgrade -y
apt install -y curl wget gnupg2 software-properties-common lsb-release apt-transport-https \
  ca-certificates git jq make python3-pip nfs-common

# Disable swap (required by kubeadm)
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab

# Kernel modules & sysctl tuning
modprobe overlay
modprobe br_netfilter
cat <<EOT | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOT

cat <<EOT | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                = 1
EOT
sysctl --system

# ----------------------
# STEP 2. INSTALL CONTAINERD
# ----------------------
apt install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# ----------------------
# STEP 3. INSTALL KUBERNETES
# ----------------------
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list
apt update && apt install -y kubelet=$K8S_VERSION kubeadm=$K8S_VERSION kubectl=$K8S_VERSION
apt-mark hold kubelet kubeadm kubectl

# Init Kubernetes
kubeadm init --pod-network-cidr=$POD_CIDR

# Configure kubectl for non-root user
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Enable single-node scheduling
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# ----------------------
# STEP 4. INSTALL CALICO CNI
# ----------------------
curl -L -o calico.yaml https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/calico.yaml
kubectl apply -f calico.yaml

# ----------------------
# STEP 5. INSTALL HELM + OSH PLUGIN
# ----------------------
curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm plugin install https://opendev.org/openstack/openstack-helm-plugin || true

# ----------------------
# STEP 6. CLONE REPOS
# ----------------------
cd /opt
[ -d openstack-helm-infra ] || git clone $OSH_INFRA_REPO
[ -d openstack-helm ] || git clone $OSH_REPO

# ----------------------
# STEP 7. METALLB (EXTERNAL IP)
# ----------------------
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo update
helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace

# Wait for MetalLB
kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=180s || true
kubectl -n metallb-system rollout status ds/metallb-speaker --timeout=180s || true

cat <<EOT | kubectl apply -f -
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
EOT

# ----------------------
# STEP 8. DEPLOY OSH-INFRA
# ----------------------
cd /opt/openstack-helm-infra
make all

# Base infra
./tools/deployment/component/ingress.sh
./tools/deployment/component/ceph.sh
./tools/deployment/component/databases.sh
./tools/deployment/component/rabbitmq.sh
./tools/deployment/component/memcached.sh
./tools/deployment/component/keystone.sh

# OVN northd + db + controllers if available
if [ -f ./tools/deployment/component/ovn.sh ]; then
  ./tools/deployment/component/ovn.sh
else
  echo "[INFO] OVN infra script not found in OSH-Infra. Skipping OVN central deploy here."
fi

# Ensure ingress Service is LoadBalancer to get MetalLB IP
for ns in ingress-nginx ingress kube-system osh-infra openstack; do
  kubectl -n "$ns" get svc >/dev/null 2>&1 || continue
  for svc in $(kubectl -n "$ns" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if echo "$svc" | grep -qiE 'ingress|nginx'; then
      kubectl -n "$ns" patch svc "$svc" -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null 2>&1 || true
    fi
  done
done

# ----------------------
# STEP 9. DEPLOY OPENSTACK SERVICES (OVN)
# ----------------------
cd /opt/openstack-helm
make all
./tools/deployment/component/glance.sh
./tools/deployment/component/nova.sh

# Prefer Neutron with OVN if script exists
if [ -f ./tools/deployment/component/neutron-ovn.sh ]; then
  ./tools/deployment/component/neutron-ovn.sh
else
  echo "[WARN] neutron-ovn.sh not found. Falling back to default neutron.sh (likely OVS)."
  ./tools/deployment/component/neutron.sh
fi
./tools/deployment/component/horizon.sh
./tools/deployment/component/cinder.sh

# ----------------------
# STEP 10. VERIFY
# ----------------------
kubectl get pods -A
helm list -A

# Show external IPs provisioned by MetalLB
kubectl get svc -A | awk 'NR==1 || $5=="LoadBalancer" {print $0}'

# Done
echo "Deployment finished"
