# openstack-install

This repository provides a Bash script for deploying a single-node OpenStack-Helm environment on MicroK8s.

## Usage

Run the deployment script with root privileges:

```bash
sudo ./deploy.sh
```

The script installs prerequisites, configures MicroK8s, prepares LVM storage for Cinder, and deploys the core OpenStack services (MariaDB, RabbitMQ, Memcached, Keystone, Glance, Open vSwitch, Neutron, Libvirt, Nova, Cinder, Horizon).
