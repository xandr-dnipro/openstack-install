#!/usr/bin/env bash
# One-node OpenStack-Helm on MicroK8s (Ubuntu 22.04/24.04)
# Після виконання мають піднятися: MariaDB, RabbitMQ, Memcached, Keystone, Glance, Open vSwitch,
# Neutron, Libvirt, Nova, Cinder (LVM), Horizon.
# Перевірено для ноди 32 ГБ RAM. Логи українською.

set -euo pipefail

# -------- Бінарники (абсолютні шляхи snap) --------
MICROK8S="/snap/bin/microk8s"
KUBECTL="/snap/bin/microk8s.kubectl"
HELM="/snap/bin/microk8s.helm3"
CURL="/usr/bin/curl"
GIT="/usr/bin/git"
APT="/usr/bin/apt-get"

# -------- Константи --------
NS="openstack"
EXPECTED_IP="10.0.0.30"
EXPECTED_HOSTNAME="openstack.local"

OSH_DIR="/opt/osh"
OSH_PATH="${OSH_DIR}/openstack-helm"
VALUES_DIR="${OSH_DIR}/values"

DEFAULT_VALUES="${VALUES_DIR}/_global-min.yaml"
RABBIT_VALUES="${VALUES_DIR}/rabbitmq.yaml"
MARIADB_VALUES="${VALUES_DIR}/mariadb.yaml"
MEMCACHED_VALUES="${VALUES_DIR}/memcached.yaml"
KEYSTONE_VALUES="${VALUES_DIR}/keystone.yaml"
GLANCE_VALUES="${VALUES_DIR}/glance.yaml"
NEUTRON_VALUES="${VALUES_DIR}/neutron.yaml"
LIBVIRT_VALUES="${VALUES_DIR}/libvirt.yaml"
NOVA_VALUES="${VALUES_DIR}/nova.yaml"
CINDER_VALUES="${VALUES_DIR}/cinder.yaml"
HORIZON_VALUES="${VALUES_DIR}/horizon.yaml"
GLANCE_PVC="${VALUES_DIR}/glance-pvc.yaml"

RETRY_HELM=5
WAIT_TIMEOUT=900
MIN_FREE_MB=2048

CINDER_IMG="/var/lib/cinder-lvm.img"
CINDER_SIZE="40G"
CINDER_VG="cinder-volumes"

# -------- Логи --------
ts(){ date +"[ %Y-%m-%d %H:%M:%S ]"; }
log(){ echo -e "$(ts) [INFO] $*"; }
warn(){ echo -e "$(ts) [WARN] $*"; }
err(){ echo -e "$(ts) [ERROR] $*" >&2; }

# -------- Хелпери --------
free_mb(){ awk '/MemAvailable/ {printf "%d\n",$2/1024}' /proc/meminfo; }
need_mem(){
  local need=${1:-$MIN_FREE_MB}; local have; have="$(free_mb || echo 0)"
  if (( have < need )); then warn "Вільної пам'яті мало (${have}MB < ${need}MB). Продовжую."; else log "Вільна RAM ${have}MB ≥ ${need}MB"; fi
}

wait_selector_ready(){
  local selector="$1"; local ns="${2:-$NS}"; local timeout="${3:-$WAIT_TIMEOUT}"
  log "Wait up to ${timeout}s for selector='${selector}' in ns=${ns}..."
  local end=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < end )); do
    mapfile -t rows < <("$KUBECTL" -n "$ns" get pods -l "$selector" --no-headers 2>/dev/null | awk '!/Completed/ {print $2}')
    if ((${#rows[@]}==0)); then sleep 4; continue; fi
    local notready=0
    for st in "${rows[@]}"; do
      [[ "$st" == */* ]] || { notready=1; break; }
      local r=${st%/*} t=${st#*/}
      (( r < t )) && { notready=1; break; }
    done
    (( notready==0 )) && { log "Selector '${selector}' ready."; return 0; }
    sleep 6
  done
  warn "Таймаут selector='${selector}'"
  "$KUBECTL" -n "$ns" get pods -l "$selector" || true
  return 1
}

restart_stuck_pods(){
  local selector="$1"; local ns="${2:-$NS}"; local age=90
  log "Recreate stuck pods (selector='${selector}', older than ${age}s)..."
  mapfile -t lines < <("$KUBECTL" -n "$ns" get pods -l "$selector" --no-headers \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason,START:.status.startTime' 2>/dev/null || true)
  local now; now=$(date +%s)
  for l in "${lines[@]:-}"; do
    local name phase reason start; name=$(awk '{print $1}'<<<"$l"); phase=$(awk '{print $2}'<<<"$l"); reason=$(awk '{print $3}'<<<"$l"); start=$(awk '{print $4}'<<<"$l")
    [[ -z "$name" || -z "$start" ]] && continue
    local s; s=$(date -d "$start" +%s 2>/dev/null || echo "$now")
    local lived=$(( now - s ))
    if (( lived >= age )) && [[ "$phase" =~ ^(Pending|Unknown)$ || "$reason" =~ ^(ContainersNotReady|ContainerCreating)$ ]]; then
      warn "Delete stuck pod ${name} (phase=${phase} reason=${reason} age=${lived}s)"
      "$KUBECTL" -n "$ns" delete pod "$name" --grace-period=0 --force || true
    fi
  done
}

clean_failed_jobs(){
  local ns="${1:-$NS}"
  mapfile -t failed < <("$KUBECTL" -n "$ns" get jobs -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[*]}{.type}{"="}{.status}{";"}{end}{"\n"}{end}' 2>/dev/null \
    | awk 'NF && /Failed=True/ {print $1}')
  for j in "${failed[@]:-}"; do
    [[ -n "$j" ]] || continue
    warn "Delete failed job ${j}"
    "$KUBECTL" -n "$ns" delete job "$j" || true
  done
}

delete_job_if_exists(){
  local name="$1"; local ns="${2:-$NS}"
  [[ -n "$name" ]] || return 0
  if "$KUBECTL" -n "$ns" get job "$name" >/dev/null 2>&1; then
    warn "Deleting job ${name}"
    "$KUBECTL" -n "$ns" delete job "$name" || true
  fi
}

retry_helm_install(){
  local release="$1"; local chart_dir="$2"; shift 2
  need_mem "$MIN_FREE_MB"
  log "helm dep up: ${chart_dir}"
  "$HELM" dep up "$chart_dir"
  for i in $(seq 1 "$RETRY_HELM"); do
    log "helm upgrade --install ${release} (try ${i}/${RETRY_HELM})"
    if "$HELM" upgrade --install "$release" "$chart_dir" -n "$NS" "$@" ; then
      return 0
    fi
    warn "Helm ${release} failed; heal & retry"
    clean_failed_jobs "$NS"
    restart_stuck_pods "application=${release}" "$NS" 90
    # окрема обробка rabbitmq hooks cluster-wait
    if [[ "$release" == "rabbitmq" ]]; then
      delete_job_if_exists "rabbitmq-cluster-wait" "$NS"
    fi
    sleep 15
  done
  err "Helm release '${release}' failed after ${RETRY_HELM} tries"
  return 1
}

wait_keystone_api(){
  local timeout=420; log "Чекаю Keystone API (до ${timeout}s)"
  local end=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < end )); do
    if "$KUBECTL" -n "$NS" get svc keystone-api >/dev/null 2>&1; then
      local ip; ip=$("$KUBECTL" -n "$NS" get svc keystone-api -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
      if [[ -n "$ip" ]] && "$CURL" -fsS "http://${ip}:5000/v3/" >/dev/null 2>&1; then
        log "Keystone API відповідає."; return 0
      fi
    fi
    restart_stuck_pods "application=keystone" "$NS" 90
    sleep 5
  done
  warn "Keystone API не доступний вчасно"
  return 1
}

# -------- Підготовка хоста --------
install_prereqs(){
  log "Install prerequisites (lvm2 git curl)"
  DEBIAN_FRONTEND=noninteractive "$APT" update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive "$APT" install -y lvm2 git curl >/dev/null
}

disable_swap(){
  log "Disable swap & comment it in /etc/fstab (idempotent)"
  swapoff -a || true
  if grep -Eqs '^[^#].*\s+swap\s' /etc/fstab; then
    sed -ri 's/^(\s*[^#]\S+\s+\S+\s+swap\s+\S+.*)$/# \1  # disabled by deploy.sh/g' /etc/fstab || true
  fi
}

sysctl_tune(){
  log "Tune sysctl"
  cat >/etc/sysctl.d/99-openstack.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
vm.max_map_count=262144
SYSCTL
  modprobe br_netfilter || true
  sysctl --system >/dev/null || true
}

hostname_hosts(){
  local curhn; curhn="$(hostname -f 2>/dev/null || hostname)"
  if [[ "$curhn" != "$EXPECTED_HOSTNAME" ]]; then
    warn "Hostname now: ${curhn}, desired: ${EXPECTED_HOSTNAME}. НЕ змінюю автоматично."
    warn "Головне — не змінюйте hostname/IP під час деплою."
  fi
  if ! grep -qE "^[[:space:]]*${EXPECTED_IP}[[:space:]]+${EXPECTED_HOSTNAME}( |$)" /etc/hosts; then
    log "Add /etc/hosts mapping: ${EXPECTED_IP} ${EXPECTED_HOSTNAME}"
    echo "${EXPECTED_IP} ${EXPECTED_HOSTNAME}" >> /etc/hosts
  fi
}

install_microk8s(){
  log "Install MicroK8s (--classic) if missing"
  if ! snap list microk8s >/dev/null 2>&1; then
    sudo snap install microk8s --channel=1.32/stable --classic
  fi
  "$MICROK8S" status --wait-ready
}

enable_addons(){
  log "Enable addons: dns, rbac, helm3, hostpath-storage, ingress"
  "$MICROK8S" enable dns || true
  "$MICROK8S" enable rbac || true
  "$MICROK8S" enable helm3 || true
  "$MICROK8S" enable hostpath-storage || true
  "$MICROK8S" enable ingress || true
}

label_node(){
  log "Label node (control-plane, compute, openvswitch)"
  local node; node=$("$KUBECTL" get nodes -o jsonpath='{.items[0].metadata.name}')
  "$KUBECTL" label nodes "$node" openstack-control-plane=enabled --overwrite || true
  "$KUBECTL" label nodes "$node" openstack-compute-node=enabled --overwrite || true
  "$KUBECTL" label nodes "$node" openvswitch=enabled --overwrite || true
}

setup_storageclass(){
  log "Create StorageClass 'general' and set default"
  cat <<'YAML' | "$KUBECTL" apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: general
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: microk8s.io/hostpath
reclaimPolicy: Delete
volumeBindingMode: Immediate
YAML
  "$KUBECTL" patch storageclass microk8s-hostpath -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true
}

ensure_ns(){
  log "Ensure namespace '${NS}'"
  "$KUBECTL" create ns "$NS" 2>/dev/null || true
}

setup_cinder_loop(){
  log "Prepare Cinder loopback ${CINDER_IMG} ${CINDER_SIZE}"
  mkdir -p "$(dirname "$CINDER_IMG")"
  if [[ ! -f "$CINDER_IMG" ]]; then
    truncate -s "$CINDER_SIZE" "$CINDER_IMG"
  fi

  # systemd unit для автопідняття loop
  cat >/etc/systemd/system/cinder-loop.service <<'EOF'
[Unit]
Description=Attach loop device for Cinder LVM
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/losetup -fP ${CINDER_IMG}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cinder-loop.service

  # Прив'язати loop зараз
  losetup -fP "$CINDER_IMG" || true
  local loopdev; loopdev=$(losetup -j "$CINDER_IMG" | awk -F: '{print $1}')
  if [[ -z "${loopdev}" ]]; then
    err "Не вдалось створити loop для ${CINDER_IMG}"; exit 1
  fi
  pvcreate -ff -y "$loopdev" >/dev/null 2>&1 || true
  if ! vgs "$CINDER_VG" >/dev/null 2>&1; then
    vgcreate "$CINDER_VG" "$loopdev" >/dev/null 2>&1 || true
  fi
  vgchange -ay "$CINDER_VG" >/dev/null 2>&1 || true
}

clone_osh(){
  log "Clone openstack-helm"
  mkdir -p "$OSH_DIR"
  if [[ ! -d "$OSH_PATH/.git" ]]; then
    "$GIT" clone https://opendev.org/openstack/openstack-helm "$OSH_PATH"
  else
    (cd "$OSH_PATH" && "$GIT" pull --ff-only)
  fi
}

write_values(){
  log "Write minimal override values"
  mkdir -p "$VALUES_DIR"

  # Глобальні
  cat >"$DEFAULT_VALUES" <<'YAML'
# Загальні налаштування для одновузлового деплою
pod:
  node_selector_key: openstack-control-plane
  node_selector_value: enabled
  resources:
    enabled: true
    default:
      requests: {cpu: "100m", memory: "128Mi"}
      limits:   {cpu: "1000m", memory: "512Mi"}
manifests:
  network_policy: false
storageclass:
  name: general
volume:
  class_name: general
YAML

  # MariaDB — один репліка, зменшені ресурси
  cat >"$MARIADB_VALUES" <<'YAML'
pod:
  replicas:
    server: 1
    controller: 1
  resources:
    enabled: true
    server:
      requests: {cpu: "300m", memory: "768Mi"}
      limits:   {cpu: "1500m", memory: "2048Mi"}
    controller:
      requests: {cpu: "200m", memory: "256Mi"}
      limits:   {cpu: "1000m", memory: "512Mi"}
YAML

  # RabbitMQ — критичний фікс диска
  cat >"$RABBIT_VALUES" <<'YAML'
pod:
  replicas:
    server: 1
  resources:
    enabled: true
    server:
      requests: {cpu: "300m", memory: "768Mi"}
      limits:   {cpu: "1500m", memory: "2048Mi"}
conf:
  rabbitmq:
    additional_config: |
      vm_memory_high_watermark.relative = 0.6
      disk_free_limit.absolute = 512MB
      loopback_users.guest = false
manifests:
  network_policy: false
YAML

  # Memcached
  cat >"$MEMCACHED_VALUES" <<'YAML'
pod:
  replicas:
    server: 1
  resources:
    enabled: true
    server:
      requests: {cpu: "50m", memory: "64Mi"}
      limits:   {cpu: "500m", memory: "256Mi"}
YAML

  # Keystone
  cat >"$KEYSTONE_VALUES" <<'YAML'
pod:
  replicas:
    api: 1
  resources:
    enabled: true
    api:
      requests: {cpu: "200m", memory: "256Mi"}
      limits:   {cpu: "1000m", memory: "512Mi"}
manifests:
  network_policy: false
YAML

  # Glance — file backend
  cat >"$GLANCE_VALUES" <<'YAML'
conf:
  glance:
    DEFAULT:
      enabled_backends: file:file
    glance_store:
      default_backend: file
manifests:
  network_policy: false
pod:
  replicas:
    api: 1
  resources:
    enabled: true
    api:
      requests: {cpu: "200m", memory: "256Mi"}
      limits:   {cpu: "1000m", memory: "512Mi"}
YAML

  # Neutron
  cat >"$NEUTRON_VALUES" <<'YAML'
pod:
  resources:
    enabled: true
    server:
      requests: {cpu: "200m", memory: "256Mi"}
      limits:   {cpu: "1000m", memory: "512Mi"}
manifests:
  network_policy: false
YAML

  # Libvirt
  cat >"$LIBVIRT_VALUES" <<'YAML'
pod:
  resources:
    enabled: true
    compute:
      requests: {cpu: "200m", memory: "256Mi"}
      limits:   {cpu: "2000m", memory: "1024Mi"}
manifests:
  network_policy: false
YAML

  # Nova
  cat >"$NOVA_VALUES" <<'YAML'
pod:
  resources:
    enabled: true
    api_metadata:
      requests: {cpu: "100m", memory: "192Mi"}
      limits:   {cpu: "500m",  memory: "512Mi"}
    api_osapi:
      requests: {cpu: "150m", memory: "256Mi"}
      limits:   {cpu: "800m", memory: "768Mi"}
    conductor:
      requests: {cpu: "150m", memory: "256Mi"}
      limits:   {cpu: "800m", memory: "768Mi"}
    scheduler:
      requests: {cpu: "100m", memory: "192Mi"}
      limits:   {cpu: "500m", memory: "512Mi"}
    novncproxy:
      requests: {cpu: "50m",  memory: "128Mi"}
      limits:   {cpu: "500m", memory: "384Mi"}
manifests:
  network_policy: false
YAML

  # Cinder — LVM backend на VG cinder-volumes
  cat >"$CINDER_VALUES" <<YAML
conf:
  cinder:
    DEFAULT:
      enabled_backends: lvm:lvm
      glance_api_servers: http://glance-api.openstack.svc.cluster.local:9292
      default_volume_type: lvm
    lvm:
      volume_driver: cinder.volume.drivers.lvm.LVMVolumeDriver
      volume_group: ${CINDER_VG}
      volumes_dir: /var/lib/cinder
      iscsi_helper: tgtadm
manifests:
  network_policy: false
pod:
  resources:
    enabled: true
    api:
      requests: {cpu: "150m", memory: "256Mi"}
      limits:   {cpu: "800m", memory: "768Mi"}
    scheduler:
      requests: {cpu: "100m", memory: "192Mi"}
      limits:   {cpu: "500m", memory: "512Mi"}
    volume:
      requests: {cpu: "150m", memory: "256Mi"}
      limits:   {cpu: "800m", memory: "768Mi"}
YAML

  # Horizon
  cat >"$HORIZON_VALUES" <<'YAML'
pod:
  resources:
    enabled: true
    server:
      requests: {cpu: "50m", memory: "128Mi"}
      limits:   {cpu: "500m", memory: "384Mi"}
manifests:
  network_policy: false
YAML

  # Glance PVC
  cat >"$GLANCE_PVC" <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: glance-images-pvc
  namespace: openstack
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: general
  resources:
    requests:
      storage: 20Gi
YAML
  "$KUBECTL" apply -f "$GLANCE_PVC"
}

# -------- Деплой хартів --------
deploy_chart(){
  local rel="$1"; local dir="${OSH_PATH}/${rel}"; shift || true
  retry_helm_install "$rel" "$dir" -n "$NS" -f "$DEFAULT_VALUES" "$@" || true
}

deploy_infra(){
  log "=== Deploy INFRA: mariadb -> rabbitmq -> memcached ==="
  need_mem

  # MariaDB
  deploy_chart mariadb -f "$MARIADB_VALUES" --wait --timeout 10m0s
  wait_selector_ready "application=mariadb" "$NS" 600 || true

  # RabbitMQ (з фіксами)
  deploy_chart rabbitmq -f "$RABBIT_VALUES" --timeout 10m0s
  # Після інсталяції дочекаємось readiness
  if ! wait_selector_ready "application=rabbitmq" "$NS" 600; then
    # самолікування кілька раундів
    for r in 1 2 3; do
      warn "RabbitMQ ще не готовий (спроба ${r}) — лікування"
      delete_job_if_exists "rabbitmq-cluster-wait" "$NS"
      restart_stuck_pods "application=rabbitmq" "$NS" 90
      sleep 15
      wait_selector_ready "application=rabbitmq" "$NS" 600 && break || true
    done
  fi

  # Memcached
  deploy_chart memcached -f "$MEMCACHED_VALUES" --wait --timeout 10m0s
  wait_selector_ready "application=memcached" "$NS" 600 || true
}

deploy_core(){
  # Keystone
  deploy_chart keystone -f "$KEYSTONE_VALUES" --wait --timeout 10m0s
  wait_selector_ready "application=keystone" "$NS" 900 || true
  wait_keystone_api || true

  # Glance
  deploy_chart glance -f "$GLANCE_VALUES" --wait --timeout 10m0s
  wait_selector_ready "application=glance" "$NS" 900 || true

  # OVS
  deploy_chart openvswitch --wait --timeout 10m0s
  wait_selector_ready "application=openvswitch" "$NS" 600 || true

  # Neutron
  deploy_chart neutron -f "$NEUTRON_VALUES" --timeout 10m0s
  wait_selector_ready "application=neutron" "$NS" 900 || true

  # Libvirt
  deploy_chart libvirt -f "$LIBVIRT_VALUES" --timeout 10m0s
  wait_selector_ready "application=libvirt" "$NS" 900 || true

  # Nova
  deploy_chart nova -f "$NOVA_VALUES" --timeout 15m0s
  wait_selector_ready "application=nova" "$NS" 900 || true

  # Cinder
  deploy_chart cinder -f "$CINDER_VALUES" --timeout 15m0s
  wait_selector_ready "application=cinder" "$NS" 900 || true

  # Horizon
  deploy_chart horizon -f "$HORIZON_VALUES" --wait --timeout 10m0s
  wait_selector_ready "application=horizon" "$NS" 900 || true
}

quick_status(){
  log "=== Quick status ==="
  "$KUBECTL" -n "$NS" get pods -o wide || true
  log "=== Helm releases ==="
  "$HELM" list -n "$NS" || true
  cat <<'MSG'

Готово. Якщо якийсь pod ще не Ready:
  /snap/bin/microk8s.kubectl -n openstack get pods
  /snap/bin/microk8s.kubectl -n openstack describe pod <pod>
  /snap/bin/microk8s.kubectl -n openstack logs <pod> -c <container>

Horizon (ClusterIP): порт-проксі локально:
  /snap/bin/microk8s.kubectl -n openstack port-forward svc/horizon 8080:80

Перевірка Keystone:
  SVC_IP=$(/snap/bin/microk8s.kubectl -n openstack get svc keystone-api -o jsonpath='{.spec.clusterIP}')
  curl -fsS "http://$SVC_IP:5000/v3/" && echo "Keystone OK"
MSG
}

main(){
  install_prereqs
  disable_swap
  sysctl_tune
  hostname_hosts
  install_microk8s
  enable_addons
  label_node
  setup_storageclass
  ensure_ns
  setup_cinder_loop
  clone_osh
  write_values
  need_mem
  deploy_infra
  deploy_core
  quick_status
}

main "$@"
