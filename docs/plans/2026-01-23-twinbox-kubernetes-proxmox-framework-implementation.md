# Twinbox Kubernetes-Proxmox Framework Implementation Plan

**Goal:** Implement a modular, automated framework that deploys production-ready Kubernetes clusters on Proxmox with integrated storage, networking, security, and monitoring.

**Architecture:** Terraform-first approach for infrastructure provisioning combined with Ansible for Kubernetes configuration management, following a modular design with separate components for infrastructure, Kubernetes, storage, networking, security, and monitoring.

**Tech Stack:** Terraform, Ansible, Proxmox VE, Kubernetes, Calico/Cilium, MetalLB, Prometheus/Grafana, containerd

---

## Phase 1: Core Infrastructure Setup

### Task 1: Initialize Project Structure

**Files:**
- Create: `twinbox/README.md`
- Create: `twinbox/LICENSE`
- Create: `twinbox/.gitignore`
- Create: `twinbox/terraform/main.tf`
- Create: `twinbox/terraform/variables.tf`
- Create: `twinbox/terraform/outputs.tf`
- Create: `twinbox/ansible/playbook.yml`
- Create: `twinbox/ansible/inventory.ini`
- Create: `twinbox/ansible/group_vars/all.yml`
- Create: `twinbox/scripts/deploy.sh`

**Step 1: Create README.md**
```markdown
# Twinbox - Kubernetes on Proxmox Framework

An automated framework for deploying production-ready Kubernetes clusters on Proxmox environments.

## Prerequisites

- Proxmox VE 7.0+
- Terraform v1.0+
- Ansible 2.10+
- SSH access to Proxmox host

## Quick Start

```bash
./scripts/deploy.sh
```

## Configuration

See `terraform/variables.tf` for configurable parameters.
```

**Step 2: Create LICENSE**
```text
MIT License

Copyright (c) 2026 Twinbox Authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

**Step 3: Create .gitignore**
```text
# Terraform
.terraform/
*.tfstate
*.tfstate.backup
*.tfvars
.terraform.lock.hcl

# Ansible
*.retry
inventory/vagrant
.vagrant/

# OS
.DS_Store
Thumbs.db
```

**Step 4: Create terraform/main.tf**
```hcl
terraform {
  required_version = ">= 1.0"
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 2.9"
    }
  }
}

provider "proxmox" {
  pm_api_url      = var.proxmox_api_url
  pm_user         = var.proxmox_user
  pm_password     = var.proxmox_password
  pm_tls_insecure = var.proxmox_tls_insecure
}

resource "proxmox_vm_qemu" "k8s_master" {
  count = var.master_count

  name        = "${var.cluster_name}-master-${count.index + 1}"
  target_node = var.target_node
  clone       = var.vm_template
  full_clone  = true

  cores   = var.master_cores
  memory  = var.master_memory
  scsihw  = "virtio-scsi-pci"

  disk {
    slot    = 0
    size    = var.master_disk_size
    type    = "scsi"
    storage = var.storage_pool
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
  }

  lifecycle {
    ignore_changes = [
      network,
    ]
  }
}

resource "proxmox_vm_qemu" "k8s_worker" {
  count = var.worker_count

  name        = "${var.cluster_name}-worker-${count.index + 1}"
  target_node = var.target_node
  clone       = var.vm_template
  full_clone  = true

  cores   = var.worker_cores
  memory  = var.worker_memory
  scsihw  = "virtio-scsi-pci"

  disk {
    slot    = 0
    size    = var.worker_disk_size
    type    = "scsi"
    storage = var.storage_pool
  }

  network {
    model  = "virtio"
    bridge = var.network_bridge
  }

  lifecycle {
    ignore_changes = [
      network,
    ]
  }
}
```

**Step 5: Create terraform/variables.tf**
```hcl
variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "proxmox_user" {
  description = "Proxmox username"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification for Proxmox API"
  type        = bool
  default     = true
}

variable "target_node" {
  description = "Target Proxmox node for VM deployment"
  type        = string
  default     = "pve"
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "twinbox-cluster"
}

variable "vm_template" {
  description = "Base VM template for Kubernetes nodes"
  type        = string
  default     = "ubuntu-template"
}

variable "storage_pool" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Network bridge for VMs"
  type        = string
  default     = "vmbr0"
}

variable "master_count" {
  description = "Number of master nodes"
  type        = number
  default     = 1
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "master_cores" {
  description = "CPU cores for master nodes"
  type        = number
  default     = 2
}

variable "master_memory" {
  description = "Memory (MB) for master nodes"
  type        = number
  default     = 4096
}

variable "master_disk_size" {
  description = "Disk size (GB) for master nodes"
  type        = string
  default     = "20G"
}

variable "worker_cores" {
  description = "CPU cores for worker nodes"
  type        = number
  default     = 2
}

variable "worker_memory" {
  description = "Memory (MB) for worker nodes"
  type        = number
  default     = 4096
}

variable "worker_disk_size" {
  description = "Disk size (GB) for worker nodes"
  type        = string
  default     = "40G"
}
```

**Step 6: Create terraform/outputs.tf**
```hcl
output "master_nodes" {
  description = "Master node information"
  value = {
    for i, vm in proxmox_vm_qemu.k8s_master :
    "master-${i}" => {
      id        = vm.id
      name      = vm.name
      ip_address = vm.default_ipv4_address
      node      = vm.target_node
    }
  }
  sensitive = true
}

output "worker_nodes" {
  description = "Worker node information"
  value = {
    for i, vm in proxmox_vm_qemu.k8s_worker :
    "worker-${i}" => {
      id        = vm.id
      name      = vm.name
      ip_address = vm.default_ipv4_address
      node      = vm.target_node
    }
  }
  sensitive = true
}

output "cluster_info" {
  description = "Cluster summary information"
  value = {
    name          = var.cluster_name
    master_count  = var.master_count
    worker_count  = var.worker_count
    total_nodes   = var.master_count + var.worker_count
  }
}
```

**Step 7: Create ansible/playbook.yml**
```yaml
---
- name: Configure Kubernetes Cluster
  hosts: k8s_cluster
  become: yes
  vars:
    kubernetes_version: "v1.28.0"
    container_runtime: "containerd"
    cni_plugin: "calico"
    pod_network_cidr: "192.168.0.0/16"
  
  pre_tasks:
    - name: Check if Kubernetes is already installed
      stat:
        path: /etc/kubernetes/admin.conf
      register: k8s_installed
    
    - name: Fail if Kubernetes is already installed
      fail:
        msg: "Kubernetes appears to be already installed. Please reset if you want to reinstall."
      when: k8s_installed.stat.exists
  
  roles:
    - { role: prerequisites, tags: ['prereqs'] }
    - { role: container_runtime, tags: ['containerd'] }
    - { role: kubeadm_setup, tags: ['kubeadm'] }
    - { role: cluster_config, tags: ['config'] }
    - { role: cni_install, tags: ['cni'] }
    - { role: addons, tags: ['addons'] }
    - { role: monitoring, tags: ['monitoring'] }
```

**Step 8: Create ansible/inventory.ini**
```ini
[k8s_cluster]
# Master nodes will be added here dynamically
[k8s_masters]
# Master nodes will be added here dynamically

[k8s_workers]
# Worker nodes will be added here dynamically

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
```

**Step 9: Create ansible/group_vars/all.yml**
```yaml
---
# Global variables for all nodes
kubernetes_version: "v1.28.0"
container_runtime: "containerd"
cni_plugin: "calico"
pod_network_cidr: "192.168.0.0/16"

# System settings
disable_swap: true
enable_kernel_modules: true
configure_firewall: true
firewall_rules:
  - { port: "6443", proto: "tcp", comment: "Kubernetes API Server" }
  - { port: "2379-2380", proto: "tcp", comment: "etcd server client API" }
  - { port: "10250", proto: "tcp", comment: "Kubelet API" }
  - { port: "10251", proto: "tcp", comment: "kube-scheduler" }
  - { port: "10252", proto: "tcp", comment: "kube-controller-manager" }
  - { port: "30000-32767", proto: "tcp", comment: "NodePort Services" }

# Network settings
cluster_cidr: "10.96.0.0/12"
service_cidr: "10.96.0.0/12"
```

**Step 10: Create scripts/deploy.sh**
```bash
#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "Starting Twinbox Kubernetes deployment..."

# Validate prerequisites
echo "Validating prerequisites..."
if ! command -v terraform &> /dev/null; then
    echo "Error: Terraform is not installed"
    exit 1
fi

if ! command -v ansible &> /dev/null; then
    echo "Error: Ansible is not installed"
    exit 1
fi

if [ ! -f "terraform/terraform.tfvars" ]; then
    echo "Warning: terraform/terraform.tfvars not found, using defaults"
fi

# Initialize Terraform
echo "Initializing Terraform..."
cd terraform
terraform init

# Plan and apply infrastructure
echo "Planning infrastructure..."
terraform plan -out=tfplan

echo "Applying infrastructure..."
terraform apply tfplan

# Get VM IP addresses and update Ansible inventory
echo "Updating Ansible inventory..."
cd ..

# Generate inventory based on Terraform outputs
cat > ansible/inventory.ini << EOF
[k8s_cluster]
$(terraform -chdir=terraform output -raw master_nodes | jq -r 'to_entries[] | "\(.value.name) ansible_host=\(.value.ip_address)"')
$(terraform -chdir=terraform output -raw worker_nodes | jq -r 'to_entries[] | "\(.value.name) ansible_host=\(.value.ip_address)"')

[k8s_masters]
$(terraform -chdir=terraform output -raw master_nodes | jq -r 'to_entries[] | "\(.value.name)"')

[k8s_workers]
$(terraform -chdir=terraform output -raw worker_nodes | jq -r 'to_entries[] | "\(.value.name)"')

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
EOF

# Run Ansible playbook
echo "Running Ansible playbook..."
cd ansible
ansible-playbook -i inventory.ini playbook.yml

echo "Deployment completed successfully!"
echo "Access your cluster with: kubectl --kubeconfig terraform/kubeconfig.yaml"
```

**Step 11: Make deploy.sh executable**
```bash
chmod +x scripts/deploy.sh
```

**Step 12: Commit changes**
```bash
git add .
git commit -m "Initialize Twinbox project structure with basic Terraform and Ansible scaffolding"
```

### Task 2: Implement Prerequisites Role

**Files:**
- Create: `twinbox/ansible/roles/prerequisites/tasks/main.yml`
- Create: `twinbox/ansible/roles/prerequisites/handlers/main.yml`
- Create: `twinbox/ansible/roles/prerequisites/defaults/main.yml`

**Step 1: Create ansible/roles/prerequisites/tasks/main.yml**
```yaml
---
- name: Update apt cache
  apt:
    update_cache: yes
    cache_valid_time: 3600

- name: Install required packages
  apt:
    name:
      - apt-transport-https
      - ca-certificates
      - curl
      - gnupg
      - lsb-release
      - python3-pip
      - python3-dev
      - gcc
      - conntrack
    state: present

- name: Disable swap
  command: swapoff -a
  when: disable_swap | default(true)
  register: swap_disabled
  changed_when: swap_disabled.rc == 0

- name: Comment out swap in fstab
  replace:
    path: /etc/fstab
    regexp: '^([^#].*swap.*)$'
    replace: '# \1'
  when: disable_swap | default(true)

- name: Enable kernel modules
  modprobe:
    name: "{{ item }}"
    state: present
  loop:
    - br_netfilter
    - overlay
  when: enable_kernel_modules | default(true)

- name: Load kernel modules persistently
  lineinfile:
    path: /etc/modules-load.d/k8s.conf
    line: "{{ item }}"
    create: yes
  loop:
    - br_netfilter
    - overlay
  when: enable_kernel_modules | default(true)

- name: Set sysctl parameters for Kubernetes
  sysctl:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    state: present
    reload: yes
  loop:
    - { name: "net.ipv4.ip_forward", value: "1" }
    - { name: "net.bridge.bridge-nf-call-iptables", value: "1" }
    - { name: "net.bridge.bridge-nf-call-ip6tables", value: "1" }
    - { name: "net.ipv4.ip_local_reserved_ports", value: "30000-32767" }
    - { name: "fs.inotify.max_user_watches", value: "524288" }
    - { name: "fs.inotify.max_user_instances", value: "256" }
  notify: reload sysctl

- name: Configure firewall rules
  ufw:
    rule: allow
    port: "{{ item.port }}"
    proto: "{{ item.proto }}"
    comment: "{{ item.comment }}"
  loop: "{{ firewall_rules }}"
  when: configure_firewall | default(true)

- name: Enable UFW
  ufw:
    state: enabled
  when: configure_firewall | default(true)

- name: Verify hostname resolution
  command: getent hosts {{ inventory_hostname }}
  register: hostname_check
  changed_when: false

- name: Set hostname if needed
  hostname:
    name: "{{ inventory_hostname }}"
  when: hostname_check.rc != 0
```

**Step 2: Create ansible/roles/prerequisites/handlers/main.yml**
```yaml
---
- name: reload sysctl
  command: sysctl -p
```

**Step 3: Create ansible/roles/prerequisites/defaults/main.yml**
```yaml
---
disable_swap: true
enable_kernel_modules: true
configure_firewall: true
firewall_rules:
  - { port: "6443", proto: "tcp", comment: "Kubernetes API Server" }
  - { port: "2379-2380", proto: "tcp", comment: "etcd server client API" }
  - { port: "10250", proto: "tcp", comment: "Kubelet API" }
  - { port: "10251", proto: "tcp", comment: "kube-scheduler" }
  - { port: "10252", proto: "tcp", comment: "kube-controller-manager" }
  - { port: "30000-32767", proto: "tcp", comment: "NodePort Services" }
```

**Step 4: Commit changes**
```bash
git add .
git commit -m "Add prerequisites role for Kubernetes node setup"
```

### Task 3: Implement Container Runtime Role

**Files:**
- Create: `twinbox/ansible/roles/container_runtime/tasks/main.yml`
- Create: `twinbox/ansible/roles/container_runtime/handlers/main.yml`
- Create: `twinbox/ansible/roles/container_runtime/templates/containerd-config.toml.j2`

**Step 1: Create ansible/roles/container_runtime/tasks/main.yml**
```yaml
---
- name: Add Docker apt key
  apt_key:
    url: https://download.docker.com/linux/ubuntu/gpg
    id: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
    state: present

- name: Add Docker repository
  apt_repository:
    repo: deb [arch=amd64] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable
    state: present
    filename: docker

- name: Install containerd
  apt:
    name: 
      - containerd.io
      - runc
    state: present

- name: Create containerd directory
  file:
    path: /etc/containerd
    state: directory
    mode: '0755'

- name: Configure containerd
  template:
    src: containerd-config.toml.j2
    dest: /etc/containerd/config.toml
    mode: '0644'
  notify: restart containerd

- name: Enable and start containerd service
  systemd:
    name: containerd
    enabled: yes
    state: started
    daemon_reload: yes

- name: Add Kubernetes apt key
  apt_key:
    url: https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key
    id: EA07426FBCAAE07E4CF7FBB99ADBE7A12AF6E839
    state: present

- name: Add Kubernetes apt repository
  apt_repository:
    repo: deb https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /
    state: present
    filename: kubernetes

- name: Install Kubernetes components
  apt:
    name:
      - kubelet={{ kubernetes_version.replace('v', '') }}*
      - kubeadm={{ kubernetes_version.replace('v', '') }}*
      - kubectl={{ kubernetes_version.replace('v', '') }}*
    state: present
    allow_downgrade: yes
    update_cache: yes

- name: Hold Kubernetes packages to prevent automatic updates
  dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop:
    - kubelet
    - kubeadm
    - kubectl

- name: Configure kubelet to use containerd
  lineinfile:
    path: /etc/default/kubelet
    line: KUBELET_EXTRA_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
    create: yes
    mode: '0644'

- name: Restart kubelet
  systemd:
    name: kubelet
    state: restarted
    daemon_reload: yes
```

**Step 2: Create ansible/roles/container_runtime/handlers/main.yml**
```yaml
---
- name: restart containerd
  systemd:
    name: containerd
    state: restarted
    daemon_reload: yes
```

**Step 3: Create ansible/roles/container_runtime/templates/containerd-config.toml.j2**
```toml
version = 2
imports = ["/etc/containerd/config.toml"]

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.8"
    [plugins."io.containerd.grpc.v1.cri".containerd]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
          endpoint = ["https://registry-1.docker.io"]
```

**Step 4: Commit changes**
```bash
git add .
git commit -m "Add container_runtime role for containerd setup"
```

### Task 4: Implement Kubeadm Setup Role

**Files:**
- Create: `twinbox/ansible/roles/kubeadm_setup/tasks/main.yml`
- Create: `twinbox/ansible/roles/kubeadm_setup/templates/kubeadm-config.yaml.j2`

**Step 1: Create ansible/roles/kubeadm_setup/tasks/main.yml**
```yaml
---
- name: Check if cluster is already initialized
  stat:
    path: /etc/kubernetes/admin.conf
  register: cluster_initialized

- name: Initialize cluster on master nodes
  block:
    - name: Generate kubeadm config
      template:
        src: kubeadm-config.yaml.j2
        dest: /tmp/kubeadm-config.yaml
      delegate_to: "{{ groups['k8s_masters'][0] }}"
      run_once: true

    - name: Initialize Kubernetes cluster
      command: kubeadm init --config=/tmp/kubeadm-config.yaml --upload-certs
      delegate_to: "{{ groups['k8s_masters'][0] }}"
      run_once: true
      register: kubeadm_init_result

    - name: Create .kube directory for root user
      file:
        path: /root/.kube
        state: directory
        mode: '0700'

    - name: Copy admin.conf to root .kube directory
      copy:
        src: /etc/kubernetes/admin.conf
        dest: /root/.kube/config
        remote_src: yes
        mode: '0600'
      delegate_to: "{{ groups['k8s_masters'][0] }}"
      run_once: true

    - name: Get join command
      command: kubeadm token create --print-join-command
      register: join_command
      delegate_to: "{{ groups['k8s_masters'][0] }}"
      run_once: true

    - name: Set join command fact
      set_fact:
        kubeadm_join_command: "{{ join_command.stdout }}"
      delegate_to: "{{ groups['k8s_masters'][0] }}"
      run_once: true

  when: inventory_hostname == groups['k8s_masters'][0] and not cluster_initialized.stat.exists

- name: Join worker nodes to cluster
  block:
    - name: Wait for master to be ready
      wait_for:
        host: "{{ hostvars[groups['k8s_masters'][0]].ansible_default_ipv4.address }}"
        port: 6443
        timeout: 300
        state: started

    - name: Join worker node to cluster
      command: "{{ hostvars[groups['k8s_masters'][0]]['kubeadm_join_command'] }}"
      when: inventory_hostname in groups['k8s_workers']
      register: join_result

  when: inventory_hostname in groups['k8s_workers']

- name: Install kubectl for ubuntu user
  copy:
    src: /etc/kubernetes/admin.conf
    dest: /home/ubuntu/.kube/config
    remote_src: yes
    owner: ubuntu
    group: ubuntu
    mode: '0600'
  when: inventory_hostname == groups['k8s_masters'][0]
```

**Step 2: Create ansible/roles/kubeadm_setup/templates/kubeadm-config.yaml.j2**
```yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: {{ ansible_default_ipv4.address }}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    node-labels: node-type=master
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: {{ kubernetes_version }}
controlPlaneEndpoint: {{ hostvars[groups['k8s_masters'][0]].ansible_default_ipv4.address }}:6443
imageRepository: registry.k8s.io
networking:
  dnsDomain: cluster.local
  podSubnet: {{ pod_network_cidr }}
  serviceSubnet: {{ service_cidr }}
apiServer:
  timeoutForControlPlane: 4m0s
  extraArgs:
    authorization-mode: Node,RBAC
controllerManager:
  extraArgs:
    bind-address: 0.0.0.0
scheduler:
  extraArgs:
    bind-address: 0.0.0.0
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
```

**Step 3: Commit changes**
```bash
git add .
git commit -m "Add kubeadm_setup role for cluster initialization"
```

## Phase 2: Enhanced Features

### Task 5: Implement CNI Installation Role

**Files:**
- Create: `twinbox/ansible/roles/cni_install/tasks/main.yml`
- Create: `twinbox/ansible/roles/cni_install/defaults/main.yml`

**Step 1: Create ansible/roles/cni_install/tasks/main.yml**
```yaml
---
- name: Wait for Kubernetes API to be available
  uri:
    url: https://{{ hostvars[groups['k8s_masters'][0]].ansible_default_ipv4.address }}:6443/healthz
    method: GET
    validate_certs: no
    status_code: 200
  retries: 60
  delay: 10
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply Calico CNI plugin
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  when: cni_plugin == "calico"

- name: Wait for Calico pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l k8s-app=calico-node -n kube-system --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  when: cni_plugin == "calico"
  retries: 30
  delay: 10

- name: Apply Cilium CNI plugin
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
    tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
    chmod +x /usr/local/bin/cilium
    cilium install --version v1.14.0
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  when: cni_plugin == "cilium"

- name: Wait for Cilium pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l k8s-app=cilium -n kube-system --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  when: cni_plugin == "cilium"
  retries: 30
  delay: 10
```

**Step 2: Create ansible/roles/cni_install/defaults/main.yml**
```yaml
---
cni_plugin: calico
pod_network_cidr: "192.168.0.0/16"
```

**Step 3: Commit changes**
```bash
git add .
git commit -m "Add cni_install role for network plugin setup"
```

### Task 6: Implement Addons Management Role

**Files:**
- Create: `twinbox/ansible/roles/addons/tasks/main.yml`
- Create: `twinbox/ansible/roles/addons/files/metallb-native.yaml`
- Create: `twinbox/ansible/roles/addons/files/nginx-ingress.yaml`

**Step 1: Create ansible/roles/addons/tasks/main.yml**
```yaml
---
- name: Create addons directory
  file:
    path: /tmp/addons
    state: directory
    mode: '0755'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy MetalLB manifest
  copy:
    src: metallb-native.yaml
    dest: /tmp/addons/metallb-native.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply MetalLB
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/addons/metallb-native.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for MetalLB pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app=metallb -n metallb-system --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Configure MetalLB IP pool
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: metallb.io/v1beta1
    kind: IPAddressPool
    metadata:
      name: production-pool
      namespace: metallb-system
    spec:
      addresses:
      - 192.168.1.100-192.168.1.110
    ---
    apiVersion: metallb.io/v1beta1
    kind: L2Advertisement
    metadata:
      name: production-advertisement
      namespace: metallb-system
    spec:
      ipAddressPools:
      - production-pool
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy NGINX Ingress Controller manifest
  copy:
    src: nginx-ingress.yaml
    dest: /tmp/addons/nginx-ingress.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply NGINX Ingress Controller
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/addons/nginx-ingress.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for NGINX Ingress Controller pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Create storage class for dynamic provisioning
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: fast-ssd
    provisioner: kubernetes.io/no-provisioner
    reclaimPolicy: Retain
    volumeBindingMode: WaitForFirstConsumer
    allowVolumeExpansion: true
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
```

**Step 2: Create ansible/roles/addons/files/metallb-native.yaml**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    app: metallb
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  namespace: metallb-system
  name: speaker
  labels:
    app: metallb
    component: speaker
spec:
  selector:
    matchLabels:
      app: metallb
      component: speaker
  template:
    metadata:
      labels:
        app: metallb
        component: speaker
    spec:
      containers:
      - name: speaker
        image: quay.io/metallb/speaker:v0.13.12
        args:
        - --port=7472
        - --config=config
        env:
        - name: METALLB_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: METALLB_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        - name: METALLB_ML_BIND_ADDR
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        ports:
        - name: monitoring
          containerPort: 7472
        resources:
          limits:
            cpu: 100m
            memory: 100Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
            add:
            - NET_RAW
        terminationMessagePolicy: FallbackToLogsOnError
      serviceAccountName: speaker
      terminationGracePeriodSeconds: 2
      hostNetwork: true
      nodeSelector:
        kubernetes.io/os: linux
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: metallb-system
  name: controller
  labels:
    app: metallb
    component: controller
spec:
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: metallb
      component: controller
  template:
    metadata:
      labels:
        app: metallb
        component: controller
    spec:
      containers:
      - name: controller
        image: quay.io/metallb/controller:v0.13.12
        args:
        - --port=7472
        - --config=config
        ports:
        - name: monitoring
          containerPort: 7472
        resources:
          limits:
            cpu: 100m
            memory: 100Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
            add:
            - NET_ADMIN
            - SYS_TIME
        terminationMessagePolicy: FallbackToLogsOnError
      serviceAccountName: controller
      terminationGracePeriodSeconds: 0
      nodeSelector:
        kubernetes.io/os: linux
---
apiVersion: v1
kind: ServiceAccount
metadata:
  namespace: metallb-system
  name: controller
  labels:
    app: metallb
---
apiVersion: v1
kind: ServiceAccount
metadata:
  namespace: metallb-system
  name: speaker
  labels:
    app: metallb
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metallb-system:controller
  labels:
    app: metallb
rules:
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: [""]
  resources: ["services/status"]
  verbs: ["update", "patch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metallb-system:speaker
  labels:
    app: metallb
rules:
- apiGroups: [""]
  resources: ["nodes", "namespaces", "endpoints", "pods", "services", "configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: ["apps"]
  resources: ["daemonsets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: metallb-system
  name: config-changer
  labels:
    app: metallb
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metallb-system:member
  labels:
    app: metallb
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.ext.metallb.io/aggregate-to-member: "true"
rules: []
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metallb-system:prometheus
  labels:
    app: metallb
rules:
- apiGroups: [""]
  resources: ["services", "endpoints", "pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: metallb-system
  name: config-changer
  labels:
    app: metallb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: config-changer
subjects:
- kind: ServiceAccount
  name: controller
  namespace: metallb-system
- kind: ServiceAccount
  name: speaker
  namespace: metallb-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metallb-system:controller
  labels:
    app: metallb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: metallb-system:controller
subjects:
- kind: ServiceAccount
  name: controller
  namespace: metallb-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metallb-system:speaker
  labels:
    app: metallb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: metallb-system:speaker
subjects:
- kind: ServiceAccount
  name: speaker
  namespace: metallb-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metallb-system:member
  labels:
    app: metallb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: metallb-system:member
subjects:
- kind: ServiceAccount
  name: controller
  namespace: metallb-system
- kind: ServiceAccount
  name: speaker
  namespace: metallb-system
```

**Step 3: Create ansible/roles/addons/files/nginx-ingress.yaml**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  name: ingress-nginx
---
apiVersion: v1
automountServiceAccountToken: true
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx
  namespace: ingress-nginx
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: admission-webhook
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-admission
  namespace: ingress-nginx
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx
  namespace: ingress-nginx
rules:
- apiGroups:
  - ""
  resources:
  - namespaces
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - configmaps
  - pods
  - secrets
  - endpoints
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - services
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses/status
  verbs:
  - update
- apiGroups:
  - networking.k8s.io
  resources:
  - ingressclasses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - coordination.k8s.io
  resourceNames:
  - ingress-nginx-leader
  resources:
  - leases
  verbs:
  - get
  - update
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - create
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - list
  - watch
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app.kubernetes.io/component: admission-webhook
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-admission
  namespace: ingress-nginx
rules:
- apiGroups:
  - ""
  resources:
  - secrets
  verbs:
  - get
  - create
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  - endpoints
  - nodes
  - pods
  - secrets
  - namespaces
  verbs:
  - list
  - watch
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - services
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
- apiGroups:
  - networking.k8s.io
  resources:
  - ingresses/status
  verbs:
  - update
- apiGroups:
  - networking.k8s.io
  resources:
  - ingressclasses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - list
  - watch
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app.kubernetes.io/component: admission-webhook
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-admission
rules:
- apiGroups:
  - admissionregistration.k8s.io
  resources:
  - validatingwebhookconfigurations
  verbs:
  - get
  - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx
  namespace: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ingress-nginx
subjects:
- kind: ServiceAccount
  name: ingress-nginx
  namespace: ingress-nginx
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app.kubernetes.io/component: admission-webhook
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-admission
  namespace: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ingress-nginx-admission
subjects:
- kind: ServiceAccount
  name: ingress-nginx-admission
  namespace: ingress-nginx
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx
  namespace: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ingress-nginx
subjects:
- kind: ServiceAccount
  name: ingress-nginx
  namespace: ingress-nginx
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/component: admission-webhook
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-admission
  namespace: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ingress-nginx-admission
subjects:
- kind: ServiceAccount
  name: ingress-nginx-admission
  namespace: ingress-nginx
---
apiVersion: v1
data:
  allow-snippet-annotations: "true"
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-controller
  namespace: ingress-nginx
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  externalTrafficPolicy: Local
  ipFamilies:
  - IPv4
  ipFamilyPolicy: SingleStack
  ports:
  - appProtocol:
      http: http
    name: http
    port: 80
    protocol: TCP
    targetPort: http
  - appProtocol:
      https: https
    name: https
    port: 443
    protocol: TCP
    targetPort: https
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  type: LoadBalancer
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-controller-admission
  namespace: ingress-nginx
spec:
  ports:
  - appProtocol: https
    name: https-webhook
    port: 443
    targetPort: webhook
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  minReadySeconds: 0
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app.kubernetes.io/component: controller
      app.kubernetes.io/instance: ingress-nginx
      app.kubernetes.io/name: ingress-nginx
  template:
    metadata:
      labels:
        app.kubernetes.io/component: controller
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/name: ingress-nginx
        app.kubernetes.io/part-of: ingress-nginx
        app.kubernetes.io/version: 1.9.4
    spec:
      containers:
      - args:
        - /nginx-ingress-controller
        - --election-id=ingress-nginx-leader
        - --controller-class=k8s.io/ingress-nginx
        - --ingress-class=nginx
        - --configmap=$(POD_NAMESPACE)/ingress-nginx-controller
        - --validating-webhook=:8443
        - --validating-webhook-certificate=/usr/local/certificates/cert
        - --validating-webhook-key=/usr/local/certificates/key
        - --enable-metrics=true
        - --publish-status-address=localhost
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: LD_PRELOAD
          value: /usr/local/lib/libmimalloc.so
        image: registry.k8s.io/ingress-nginx/controller:v1.9.4@sha256:5b161f051d3eb5b58e7fd1ac0ce4e8df776b65d3a2f4debad7be8e1e6edc7cc2
        lifecycle:
          preStop:
            exec:
              command:
              - /wait-shutdown
        livenessProbe:
          failureThreshold: 5
          httpGet:
            path: /healthz
            port: 10254
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 1
        name: controller
        ports:
        - containerPort: 80
          name: http
          protocol: TCP
        - containerPort: 443
          name: https
          protocol: TCP
        - containerPort: 8443
          name: webhook
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /healthz
            port: 10254
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 1
        resources:
          requests:
            cpu: 100m
            memory: 90Mi
        securityContext:
          allowPrivilegeEscalation: true
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - ALL
          runAsNonRoot: true
          runAsUser: 101
          fsGroup: 2000
        volumeMounts:
        - mountPath: /usr/local/certificates/
          name: webhook-cert
          readOnly: true
      dnsPolicy: ClusterFirst
      nodeSelector:
        kubernetes.io/os: linux
      serviceAccountName: ingress-nginx
      terminationGracePeriodSeconds: 300
      volumes:
      - name: webhook-cert
        secret:
          secretName: ingress-nginx-admission
---
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    app.kubernetes.io/component: admission-webhook
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-admission-create
  namespace: ingress-nginx
spec:
  template:
    metadata:
      labels:
        app.kubernetes.io/component: admission-webhook
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/name: ingress-nginx
        app.kubernetes.io/part-of: ingress-nginx
        app.kubernetes.io/version: 1.9.4
      name: ingress-nginx-admission-create
    spec:
      containers:
      - args:
        - create
        - --host=ingress-nginx-controller-admission,ingress-nginx-controller-admission.$(POD_NAMESPACE).svc
        - --namespace=$(POD_NAMESPACE)
        - --secret-name=ingress-nginx-admission
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        image: registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20231011-8b08c5ea8@sha256:a3ea0e40a2dc2a0d3effdefae0bda9ed4c9d2e0d4a003d5e2b9d3c7d00b03b6f
        name: create
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 65532
          seccompProfile:
            type: RuntimeDefault
      nodeSelector:
        kubernetes.io/os: linux
      restartPolicy: OnFailure
      serviceAccountName: ingress-nginx-admission
---
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    app.kubernetes.io/component: admission-webhook
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-admission-patch
  namespace: ingress-nginx
spec:
  template:
    metadata:
      labels:
        app.kubernetes.io/component: admission-webhook
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/name: ingress-nginx
        app.kubernetes.io/part-of: ingress-nginx
        app.kubernetes.io/version: 1.9.4
      name: ingress-nginx-admission-patch
    spec:
      containers:
      - args:
        - patch
        - --webhook-name=ingress-nginx-admission
        - --namespace=$(POD_NAMESPACE)
        - --patch-mutating=false
        - --secret-name=ingress-nginx-admission
        - --patch-failure-policy=Fail
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        image: registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20231011-8b08c5ea8@sha256:a3ea0e40a2dc2a0d3effdefae0bda9ed4c9d2e0d4a003d5e2b9d3c7d00b03b6f
        name: patch
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 65532
          seccompProfile:
            type: RuntimeDefault
      nodeSelector:
        kubernetes.io/os: linux
      restartPolicy: OnFailure
      serviceAccountName: ingress-nginx-admission
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: nginx
spec:
  controller: k8s.io/ingress-nginx
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  labels:
    app.kubernetes.io/component: admission-webhook
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.9.4
  name: ingress-nginx-admission
webhooks:
- admissionReviewVersions:
  - v1
  clientConfig:
    service:
      name: ingress-nginx-controller-admission
      namespace: ingress-nginx
      path: /networking/v1/ingresses
  failurePolicy: Fail
  matchPolicy: Equivalent
  name: validate.nginx.ingress.kubernetes.io
  rules:
  - apiGroups:
    - networking.k8s.io
    apiVersions:
    - v1
    operations:
    - CREATE
    - UPDATE
    resources:
    - ingresses
  sideEffects: None
```

**Step 4: Commit changes**
```bash
git add .
git commit -m "Add addons role for MetalLB and NGINX Ingress setup"
```

## Phase 3: Production Hardening

### Task 7: Implement Security Module

**Files:**
- Create: `twinbox/ansible/roles/security/tasks/main.yml`
- Create: `twinbox/ansible/roles/security/files/rbac-admin-user.yaml`
- Create: `twinbox/ansible/roles/security/files/network-policies.yaml`

**Step 1: Create ansible/roles/security/tasks/main.yml**
```yaml
---
- name: Create security manifests directory
  file:
    path: /tmp/security-manifests
    state: directory
    mode: '0755'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy RBAC admin user manifest
  copy:
    src: rbac-admin-user.yaml
    dest: /tmp/security-manifests/rbac-admin-user.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply RBAC admin user configuration
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/security-manifests/rbac-admin-user.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create admin user credentials directory
  file:
    path: /home/ubuntu/admin-user
    state: directory
    owner: ubuntu
    group: ubuntu
    mode: '0700'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Extract admin user certificate and key
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl get secret admin-user-token -n admin-user -o jsonpath='{.data.token}' | base64 -d > /tmp/admin-token.txt
    kubectl get secret admin-user-tls -n admin-user -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt
    kubectl get secret admin-user-tls -n admin-user -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/admin.crt
    kubectl get secret admin-user-tls -n admin-user -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/admin.key
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create kubectl configuration for admin user
  shell: |
    kubectl config set-credentials admin-user \
      --token=$(cat /tmp/admin-token.txt) \
      --client-certificate=/tmp/admin.crt \
      --client-key=/tmp/admin.key \
      --certificate-authority=/tmp/ca.crt
    
    kubectl config set-context admin-user@kubernetes \
      --cluster=kubernetes \
      --user=admin-user
    
    kubectl config use-context admin-user@kubernetes
    
    kubectl config view --flatten > /home/ubuntu/admin-user/config
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Set permissions for admin user config
  file:
    path: /home/ubuntu/admin-user/config
    owner: ubuntu
    group: ubuntu
    mode: '0600'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy network policies manifest
  copy:
    src: network-policies.yaml
    dest: /tmp/security-manifests/network-policies.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply network policies
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/security-manifests/network-policies.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Configure audit log policy
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: kube-apiserver-audit-policy
      namespace: kube-system
    data:
      audit-policy.yaml: |
        apiVersion: audit.k8s.io/v1
        kind: Policy
        rules:
        # Log all requests at the Metadata level.
        - level: Metadata
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Enable audit logs in kube-apiserver
  lineinfile:
    path: /etc/kubernetes/manifests/kube-apiserver.yaml
    insertafter: 'volumeMounts:'
    line: "  - mountPath: /etc/kubernetes/audit-policy.yaml"
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
```

**Step 2: Create ansible/roles/security/files/rbac-admin-user.yaml**
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: admin-user
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-user-tls
  namespace: admin-user
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/tls
data:
  tls.crt: ""
  tls.key: ""
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: admin-user
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: admin-user
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: admin-user-token
  namespace: admin-user
  annotations:
    kubernetes.io/service-account.name: admin-user
```

**Step 3: Create ansible/roles/security/files/network-policies.yaml**
```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kube-system
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-nginx
  namespace: ingress-nginx
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ingress-nginx
  policyTypes:
  - Ingress
  ingress:
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-from-other-namespaces
  namespace: kube-system
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: kube-system
```

**Step 4: Commit changes**
```bash
git add .
git commit -m "Add security role for RBAC and network policies setup"
```

### Task 8: Implement Monitoring Module

**Files:**
- Create: `twinbox/ansible/roles/monitoring/tasks/main.yml`
- Create: `twinbox/ansible/roles/monitoring/files/prometheus-stack.yaml`
- Create: `twinbox/ansible/roles/monitoring/files/grafana-dashboard.yaml`

**Step 1: Create ansible/roles/monitoring/tasks/main.yml**
```yaml
---
- name: Create monitoring manifests directory
  file:
    path: /tmp/monitoring-manifests
    state: directory
    mode: '0755'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy Prometheus stack manifest
  copy:
    src: prometheus-stack.yaml
    dest: /tmp/monitoring-manifests/prometheus-stack.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply Prometheus stack
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/monitoring-manifests/prometheus-stack.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for Prometheus pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app=prometheus -n monitoring --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Wait for Alertmanager pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app=alertmanager -n monitoring --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Wait for Grafana pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Copy Grafana dashboard manifest
  copy:
    src: grafana-dashboard.yaml
    dest: /tmp/monitoring-manifests/grafana-dashboard.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply Grafana dashboard
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/monitoring-manifests/grafana-dashboard.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Expose Grafana service via LoadBalancer
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl patch svc grafana -n monitoring -p '{"spec": {"type": "LoadBalancer"}}'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Install node-exporter for system metrics
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: node-exporter
      namespace: monitoring
      labels:
        k8s-app: node-exporter
    spec:
      selector:
        matchLabels:
          k8s-app: node-exporter
      template:
        metadata:
          labels:
            k8s-app: node-exporter
        spec:
          hostPID: true
          hostIPC: true
          hostNetwork: true
          containers:
          - name: node-exporter
            image: prom/node-exporter:v1.6.1
            ports:
            - containerPort: 9100
              protocol: TCP
              name: http-metrics
            args:
            - --collector.procfs=/host/proc
            - --collector.sysfs=/host/sys
            - --collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc)($|/)
            resources:
              requests:
                cpu: 0.15
                memory: 512Mi
              limits:
                cpu: 0.15
                memory: 512Mi
            securityContext:
              privileged: true
            volumeMounts:
            - name: dev
              mountPath: /host/dev
            - name: proc
              mountPath: /host/proc
            - name: sys
              mountPath: /host/sys
            - name: rootfs
              mountPath: /rootfs
          volumes:
          - name: dev
            hostPath:
              path: /dev
          - name: proc
            hostPath:
              path: /proc
          - name: sys
            hostPath:
              path: /sys
          - name: rootfs
            hostPath:
              path: /
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create monitoring service accounts
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: prometheus
      namespace: monitoring
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: prometheus
    rules:
    - apiGroups: [""]
      resources:
      - nodes
      - nodes/proxy
      - services
      - endpoints
      - pods
      verbs: ["get", "list", "watch"]
    - apiGroups:
      - extensions
      resources:
      - ingresses
      verbs: ["get", "list", "watch"]
    - nonResourceURLs: ["/metrics"]
      verbs: ["get"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: prometheus
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: prometheus
    subjects:
    - kind: ServiceAccount
      name: prometheus
      namespace: monitoring
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
```

**Step 2: Create ansible/roles/monitoring/files/prometheus-stack.yaml**
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
    rule_files:
      - "rules.yml"
    alerting:
      alertmanagers:
      - static_configs:
        - targets:
          - alertmanager:9093
    scrape_configs:
    - job_name: 'kubernetes-apiservers'
      kubernetes_sd_configs:
      - role: endpoints
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      relabel_configs:
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: default;kubernetes;https
    - job_name: 'kubernetes-nodes'
      kubernetes_sd_configs:
      - role: node
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics
    - job_name: 'kubernetes-pods'
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: kubernetes_pod_name
    - job_name: 'kubernetes-service-endpoints'
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_service_annotation_prometheus_io_port]
        action: replace
        target_label: __address__
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_service_name]
        action: replace
        target_label: kubernetes_name
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
      - name: prometheus
        image: prom/prometheus:v2.47.0
        args:
          - '--storage.tsdb.retention.time=30d'
          - '--config.file=/etc/prometheus/prometheus.yml'
          - '--storage.tsdb.path=/prometheus/'
          - '--web.console.libraries=/etc/prometheus/console_libraries'
          - '--web.console.templates=/etc/prometheus/consoles'
        ports:
        - containerPort: 9090
        resources:
          requests:
            cpu: 200m
            memory: 1Gi
          limits:
            cpu: 500m
            memory: 2Gi
        volumeMounts:
        - name: prometheus-config-volume
          mountPath: /etc/prometheus/
        - name: prometheus-storage-volume
          mountPath: /prometheus/
      volumes:
        - name: prometheus-config-volume
          configMap:
            defaultMode: 420
            name: prometheus-config
        - name: prometheus-storage-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: monitoring
spec:
  selector:
    app: prometheus
  type: ClusterIP
  ports:
    - port: 9090
      targetPort: 9090
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alertmanager
  template:
    metadata:
      labels:
        app: alertmanager
    spec:
      containers:
      - name: alertmanager
        image: prom/alertmanager:v0.26.0
        args:
          - '--config.file=/etc/alertmanager/config.yml'
          - '--storage.path=/alertmanager'
        ports:
        - containerPort: 9093
        resources:
          requests:
            cpu: 50m
            memory: 100Mi
          limits:
            cpu: 200m
            memory: 200Mi
        volumeMounts:
        - name: alertmanager-config-volume
          mountPath: /etc/alertmanager/
      volumes:
        - name: alertmanager-config-volume
          configMap:
            defaultMode: 420
            name: alertmanager-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: alertmanager-config
  namespace: monitoring
data:
  config.yml: |
    global:
      smtp_smarthost: 'localhost:25'
      smtp_from: 'alertmanager@localhost'
      smtp_auth_username: 'alertmanager'
      smtp_auth_password: 'password'
    route:
      receiver: 'default-receiver'
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 1h
    receivers:
    - name: 'default-receiver'
      email_configs:
      - to: 'admin@example.com'
---
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  selector:
    app: alertmanager
  type: ClusterIP
  ports:
    - port: 9093
      targetPort: 9093
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: grafana
  template:
    metadata:
      labels:
        app.kubernetes.io/name: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana-enterprise:10.1.5
        ports:
        - containerPort: 3000
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "admin123"
        - name: GF_USERS_ALLOW_SIGN_UP
          value: "false"
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 200m
            memory: 512Mi
        volumeMounts:
        - name: grafana-storage
          mountPath: /var/lib/grafana
      volumes:
      - name: grafana-storage
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: monitoring
spec:
  selector:
    app.kubernetes.io/name: grafana
  type: ClusterIP
  ports:
    - port: 3000
      targetPort: 3000
```

**Step 3: Create ansible/roles/monitoring/files/grafana-dashboard.yaml**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-prometheus
  namespace: monitoring
data:
  prometheus-dashboard.json: |-
    {
      "dashboard": {
        "id": null,
        "title": "Prometheus Stats",
        "tags": [],
        "style": "dark",
        "timezone": "browser",
        "refresh": "10s",
        "schemaVersion": 12,
        "version": 1,
        "links": [],
        "rows": [
          {
            "collapse": false,
            "editable": true,
            "height": "250px",
            "panels": [
              {
                "cacheTimeout": null,
                "colorBackground": false,
                "colorValue": false,
                "colors": [
                  "rgba(245, 54, 54, 0.9)",
                  "rgba(237, 129, 40, 0.89)",
                  "rgba(50, 172, 45, 0.97)"
                ],
                "datasource": "Prometheus",
                "decimals": 2,
                "editable": true,
                "error": false,
                "format": "bytes",
                "gauge": {
                  "maxValue": 100,
                  "minValue": 0,
                  "show": false,
                  "thresholdLabels": false,
                  "thresholdMarkers": true
                },
                "id": 2,
                "interval": null,
                "isNew": true,
                "links": [],
                "mappingType": 1,
                "mappingTypes": [
                  {
                    "name": "value to text",
                    "value": 1
                  },
                  {
                    "name": "range to text",
                    "value": 2
                  }
                ],
                "maxDataPoints": 100,
                "nullPointMode": "connected",
                "nullText": null,
                "postfix": "s",
                "postfixFontSize": "50%",
                "prefix": "",
                "prefixFontSize": "50%",
                "rangeMaps": [
                  {
                    "from": "null",
                    "text": "N/A",
                    "to": "null"
                  }
                ],
                "span": 4,
                "sparkline": {
                  "fillColor": "rgba(31, 118, 189, 0.18)",
                  "full": false,
                  "lineColor": "rgb(31, 120, 193)",
                  "show": false
                },
                "targets": [
                  {
                    "expr": "sum(container_memory_usage_bytes{container_name!=\"\"})",
                    "intervalFactor": 2,
                    "refId": "A",
                    "step": 4
                  }
                ],
                "thresholds": "",
                "title": "Total Memory Usage",
                "type": "singlestat",
                "valueFontSize": "80%",
                "valueMaps": [
                  {
                    "op": "=",
                    "text": "N/A",
                    "value": "null"
                  }
                ],
                "valueName": "current"
              },
              {
                "cacheTimeout": null,
                "colorBackground": false,
                "colorValue": false,
                "colors": [
                  "rgba(245, 54, 54, 0.9)",
                  "rgba(237, 129, 40, 0.89)",
                  "rgba(50, 172, 45, 0.97)"
                ],
                "datasource": "Prometheus",
                "decimals": 2,
                "editable": true,
                "error": false,
                "format": "none",
                "gauge": {
                  "maxValue": 100,
                  "minValue": 0,
                  "show": false,
                  "thresholdLabels": false,
                  "thresholdMarkers": true
                },
                "id": 3,
                "interval": null,
                "isNew": true,
                "links": [],
                "mappingType": 1,
                "mappingTypes": [
                  {
                    "name": "value to text",
                    "value": 1
                  },
                  {
                    "name": "range to text",
                    "value": 2
                  }
                ],
                "maxDataPoints": 100,
                "nullPointMode": "connected",
                "nullText": null,
                "postfix": "cores",
                "postfixFontSize": "50%",
                "prefix": "",
                "prefixFontSize": "50%",
                "rangeMaps": [
                  {
                    "from": "null",
                    "text": "N/A",
                    "to": "null"
                  }
                ],
                "span": 4,
                "sparkline": {
                  "fillColor": "rgba(31, 118, 189, 0.18)",
                  "full": false,
                  "lineColor": "rgb(31, 120, 193)",
                  "show": false
                },
                "targets": [
                  {
                    "expr": "sum(rate(container_cpu_usage_seconds_total{container_name!=\"\"}[5m]))",
                    "intervalFactor": 2,
                    "refId": "A",
                    "step": 4
                  }
                ],
                "thresholds": "",
                "title": "Total CPU Usage",
                "type": "singlestat",
                "valueFontSize": "80%",
                "valueMaps": [
                  {
                    "op": "=",
                    "text": "N/A",
                    "value": "null"
                  }
                ],
                "valueName": "current"
              },
              {
                "cacheTimeout": null,
                "colorBackground": false,
                "colorValue": false,
                "colors": [
                  "rgba(245, 54, 54, 0.9)",
                  "rgba(237, 129, 40, 0.89)",
                  "rgba(50, 172, 45, 0.97)"
                ],
                "datasource": "Prometheus",
                "decimals": 2,
                "editable": true,
                "error": false,
                "format": "none",
                "gauge": {
                  "maxValue": 100,
                  "minValue": 0,
                  "show": false,
                  "thresholdLabels": false,
                  "thresholdMarkers": true
                },
                "id": 4,
                "interval": null,
                "isNew": true,
                "links": [],
                "mappingType": 1,
                "mappingTypes": [
                  {
                    "name": "value to text",
                    "value": 1
                  },
                  {
                    "name": "range to text",
                    "value": 2
                  }
                ],
                "maxDataPoints": 100,
                "nullPointMode": "connected",
                "nullText": null,
                "postfix": "containers",
                "postfixFontSize": "50%",
                "prefix": "",
                "prefixFontSize": "50%",
                "rangeMaps": [
                  {
                    "from": "null",
                    "text": "N/A",
                    "to": "null"
                  }
                ],
                "span": 4,
                "sparkline": {
                  "fillColor": "rgba(31, 118, 189, 0.18)",
                  "full": false,
                  "lineColor": "rgb(31, 120, 193)",
                  "show": false
                },
                "targets": [
                  {
                    "expr": "count(container_start_time_seconds{container_name!=\"\"})",
                    "intervalFactor": 2,
                    "refId": "A",
                    "step": 4
                  }
                ],
                "thresholds": "",
                "title": "Total Running Containers",
                "type": "singlestat",
                "valueFontSize": "80%",
                "valueMaps": [
                  {
                    "op": "=",
                    "text": "N/A",
                    "value": "null"
                  }
                ],
                "valueName": "current"
              }
            ],
            "title": "Row1"
          }
        ]
      },
      "overwrite": true
    }
```

**Step 4: Commit changes**
```bash
git add .
git commit -m "Add monitoring role for Prometheus, Grafana, and AlertManager setup"
```

## Phase 4: Private Cloud Foundation

### Task 9: Implement User Management Layer

**Files:**
- Create: `twinbox/ansible/roles/user_management/tasks/main.yml`
- Create: `twinbox/ansible/roles/user_management/files/authentik-deployment.yaml`

**Step 1: Create ansible/roles/user_management/tasks/main.yml**
```yaml
---
- name: Create user management manifests directory
  file:
    path: /tmp/user-management
    state: directory
    mode: '0755'
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Copy Authentik deployment manifest
  copy:
    src: authentik-deployment.yaml
    dest: /tmp/user-management/authentik-deployment.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Apply Authentik deployment
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f /tmp/user-management/authentik-deployment.yaml
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Wait for Authentik pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app=authentik-server -n authentik --timeout=600s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 60
  delay: 10

- name: Wait for Authentik worker pods to be ready
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl wait --for=condition=ready pods -l app=authentik-worker -n authentik --timeout=300s
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
  retries: 30
  delay: 10

- name: Create namespace for user applications
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl create namespace user-applications --dry-run=client -o yaml | kubectl apply -f -
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create resource quota for user applications
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: ResourceQuota
    metadata:
      name: compute-quota
      namespace: user-applications
    spec:
      hard:
        requests.cpu: "4"
        requests.memory: 8Gi
        limits.cpu: "8"
        limits.memory: 16Gi
        persistentvolumeclaims: "10"
        services.loadbalancers: "5"
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Create limit range for user applications
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: LimitRange
    metadata:
      name: mem-limit-range
      namespace: user-applications
    spec:
      limits:
      - default:
          memory: 512Mi
          cpu: 500m
        defaultRequest:
          memory: 256Mi
          cpu: 100m
        type: Container
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true

- name: Set up namespace isolation for users
  shell: |
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl apply -f - <<EOF
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: user-applications-isolation
      namespace: user-applications
    spec:
      podSelector: {}
      policyTypes:
      - Ingress
      - Egress
      egress:
      - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
        ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
      - to:
        - namespaceSelector:
            matchLabels:
              name: monitoring
        ports:
        - protocol: TCP
          port: 9090
    EOF
  delegate_to: "{{ groups['k8s_masters'][0] }}"
  run_once: true
```

**Step 2: Create ansible/roles/user_management/files/authentik-deployment.yaml**
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: authentik
---
apiVersion: v1
kind: Secret
metadata:
  name: authentik-secret
  namespace: authentik
type: Opaque
data:
  authentik_secret_key: $(openssl rand -base64 32 | tr -d '\n' | base64)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authentik-server
  namespace: authentik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: authentik-server
  template:
    metadata:
      labels:
        app: authentik-server
    spec:
      containers:
      - name: server
        image: ghcr.io/goauthentik/server:2023.8.3
        ports:
        - containerPort: 9000
        - containerPort: 9443
        env:
        - name: AUTHENTIK_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: authentik-secret
              key: authentik_secret_key
        - name: AUTHENTIK_POSTGRESQL__HOST
          value: "postgres"
        - name: AUTHENTIK_POSTGRESQL__NAME
          value: "authentik"
        - name: AUTHENTIK_POSTGRESQL__USER
          value: "authentik"
        - name: AUTHENTIK_POSTGRESQL__PASSWORD
          value: "authentik"
        - name: AUTHENTIK_REDIS__HOST
          value: "redis"
        - name: AUTHENTIK_REDIS__PASSWORD
          value: ""
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            cpu: 500m
            memory: 1Gi
        volumeMounts:
        - name: media
          mountPath: /media
      volumes:
      - name: media
        emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authentik-worker
  namespace: authentik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: authentik-worker
  template:
    metadata:
      labels:
        app: authentik-worker
    spec:
      containers:
      - name: worker
        image: ghcr.io/goauthentik/server:2023.8.3
        command: ["/server", "worker"]
        env:
        - name: AUTHENTIK_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: authentik-secret
              key: authentik_secret_key
        - name: AUTHENTIK_POSTGRESQL__HOST
          value: "postgres"
        - name: AUTHENTIK_POSTGRESQL__NAME
          value: "authentik"
        - name: AUTHENTIK_POSTGRESQL__USER
          value: "authentik"
        - name: AUTHENTIK_POSTGRESQL__PASSWORD
          value: "authentik"
        - name: AUTHENTIK_REDIS__HOST
          value: "redis"
        - name: AUTHENTIK_REDIS__PASSWORD
          value: ""
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            cpu: 500m
            memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: authentik-server
  namespace: authentik
spec:
  selector:
    app: authentik-server
  ports:
    - protocol: TCP
      port: 9000
      targetPort: 9000
    - protocol: TCP
      port: 9443
      targetPort: 9443
  type: LoadBalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: authentik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: "authentik"
        - name: POSTGRES_USER
          value: "authentik"
        - name: POSTGRES_PASSWORD
          value: "authentik"
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 200m
            memory: 512Mi
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: postgres-data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: authentik
spec:
  selector:
    app: postgres
  ports:
    - protocol: TCP
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: authentik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 100m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: authentik
spec:
  selector:
    app: redis
  ports:
    - protocol: TCP
      port: 6379
      targetPort: 6379
```

**Step 3: Commit changes**
```bash
git add .
git commit -m "Add user_management role for Authentik identity provider setup"
```

### Task 10: Finalize Deployment Script and Documentation

**Files:**
- Modify: `twinbox/scripts/deploy.sh`
- Create: `twinbox/docs/getting-started.md`
- Create: `twinbox/docs/configuration.md`
- Create: `twinbox/docs/troubleshooting.md`

**Step 1: Enhance deployment script**
```bash
#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "Starting Twinbox Kubernetes deployment..."

# Function to print colored output
print_status() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

print_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

# Validate prerequisites
print_status "Validating prerequisites..."
if ! command -v terraform &> /dev/null; then
    print_error "Terraform is not installed"
    exit 1
fi

if ! command -v ansible &> /dev/null; then
    print_error "Ansible is not installed"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed"
    exit 1
fi

if [ ! -f "terraform/terraform.tfvars" ]; then
    print_status "Warning: terraform/terraform.tfvars not found, using defaults"
fi

# Initialize Terraform
print_status "Initializing Terraform..."
cd terraform
terraform init

# Plan and apply infrastructure
print_status "Planning infrastructure..."
terraform plan -out=tfplan

echo "Do you want to apply this plan? (yes/no): "
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    print_status "Applying infrastructure..."
    terraform apply tfplan
else
    print_status "Plan not applied. Exiting."
    exit 0
fi

# Get VM IP addresses and update Ansible inventory
print_status "Updating Ansible inventory..."
cd ..

# Generate inventory based on Terraform outputs
print_status "Generating Ansible inventory..."
cat > ansible/inventory.ini << EOF
[k8s_cluster]
$(terraform -chdir=terraform output -raw master_nodes | jq -r 'to_entries[] | "\(.value.name) ansible_host=\(.value.ip_address) ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa"')
$(terraform -chdir=terraform output -raw worker_nodes | jq -r 'to_entries[] | "\(.value.name) ansible_host=\(.value.ip_address) ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa"')

[k8s_masters]
$(terraform -chdir=terraform output -raw master_nodes | jq -r 'to_entries[] | "\(.value.name)"')

[k8s_workers]
$(terraform -chdir=terraform output -raw worker_nodes | jq -r 'to_entries[] | "\(.value.name)"')
EOF

# Run Ansible playbook
print_status "Running Ansible playbook..."
cd ansible
ansible-playbook -i inventory.ini playbook.yml

# Copy kubeconfig to home directory
print_status "Setting up kubectl configuration..."
mkdir -p ~/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config
chown $(whoami):$(id -gn $(whoami)) ~/.kube/config
chmod 600 ~/.kube/config

print_success "Deployment completed successfully!"
echo ""
echo "Your Kubernetes cluster is ready!"
echo "Access your cluster with: kubectl get nodes"
echo ""
echo "Services:"
echo "- Grafana: http://<load-balancer-ip>:3000 (admin/admin123)"
echo "- Authentik: http://<load-balancer-ip>:9000"
echo ""
print_success "Check the documentation in twinbox/docs/ for more information."
```

**Step 2: Create docs/getting-started.md**
```markdown
# Getting Started with Twinbox

Welcome to Twinbox, an automated framework for deploying production-ready Kubernetes clusters on Proxmox environments.

## Prerequisites

Before starting with Twinbox, ensure you have the following prerequisites installed:

- Proxmox VE 7.0+
- Terraform v1.0+
- Ansible 2.10+
- kubectl
- SSH access to Proxmox host
- An Ubuntu template VM prepared in Proxmox

## Quick Start

1. Clone the Twinbox repository:
   ```bash
   git clone https://github.com/your-org/twinbox.git
   cd twinbox
   ```

2. Configure your Proxmox connection details by creating `terraform/terraform.tfvars`:
   ```hcl
   proxmox_api_url = "https://your-proxmox-host:8006/api2/json"
   proxmox_user = "root@pam"
   proxmox_password = "your-password"
   target_node = "pve"
   vm_template = "ubuntu-template"
   ```

3. Run the deployment script:
   ```bash
   ./scripts/deploy.sh
   ```

4. Follow the prompts to confirm the infrastructure plan and complete the deployment.

## Accessing Your Cluster

Once deployment is complete, you can access your cluster using kubectl:

```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

## What's Included

Your Twinbox deployment includes:

- A production-ready Kubernetes cluster
- Calico CNI for networking
- MetalLB for load balancing
- NGINX Ingress Controller
- Prometheus, Grafana, and AlertManager for monitoring
- Authentik for identity management
- RBAC and network policies for security
```

**Step 3: Create docs/configuration.md**
```markdown
# Configuration Guide

This guide explains how to customize your Twinbox deployment.

## Terraform Variables

All infrastructure configuration is done through Terraform variables. Create a `terraform/terraform.tfvars` file with the following variables:

### Proxmox Connection
```hcl
proxmox_api_url      = "https://your-proxmox-host:8006/api2/json"
proxmox_user         = "root@pam"
proxmox_password     = "your-password"
proxmox_tls_insecure = true  # Set to false in production
```

### Cluster Configuration
```hcl
cluster_name    = "my-cluster"
target_node     = "pve"
vm_template     = "ubuntu-template"
storage_pool    = "local-lvm"
network_bridge  = "vmbr0"
```

### Node Specifications
```hcl
master_count       = 1
worker_count       = 2
master_cores       = 2
master_memory      = 4096
master_disk_size   = "20G"
worker_cores       = 4
worker_memory      = 8192
worker_disk_size   = "50G"
```

## Ansible Variables

Additional configuration can be set in `ansible/group_vars/all.yml`:

```yaml
kubernetes_version: "v1.28.0"
container_runtime: "containerd"
cni_plugin: "calico"  # or "cilium"
pod_network_cidr: "192.168.0.0/16"
```

## Customizing Components

### Changing the CNI Plugin

To use Cilium instead of Calico, update the `cni_plugin` variable:

```yaml
cni_plugin: "cilium"
```

### Adjusting Resource Quotas

In the user management section, you can adjust resource quotas:

```yaml
# In user management configuration
requests.cpu: "8"
requests.memory: 16Gi
limits.cpu: "16"
limits.memory: 32Gi
```

## MetalLB Configuration

The default MetalLB IP pool is configured for 192.168.1.100-192.168.1.110. To change this:

1. Edit the MetalLB configuration in the addons role
2. Update the IP range to match your network

## Storage Classes

Twinbox creates a default `fast-ssd` storage class. To customize:

1. Modify the storage class definition in the addons role
2. Adjust parameters like `provisioner`, `parameters`, and `volumeBindingMode`
```

**Step 4: Create docs/troubleshooting.md**
```markdown
# Troubleshooting Guide

This guide helps diagnose and resolve common issues with Twinbox deployments.

## Common Issues

### Terraform Errors

**Error: Failed to query available provider packages**

This usually occurs when Terraform cannot reach the provider registries. Check your internet connection and proxy settings.

**Error: Provider "proxmox" not available**

Ensure you have the correct Proxmox provider configured in your Terraform files:

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 2.9"
    }
  }
}
```

### Ansible Errors

**Error: Connection refused when connecting to VMs**

1. Verify that the VMs were created successfully in Proxmox
2. Check that the SSH keys are properly configured
3. Ensure the VMs have network connectivity

**Error: Kubernetes cluster already initialized**

If you need to redeploy, first reset the cluster:

```bash
kubeadm reset
systemctl stop kubelet
rm -rf /etc/kubernetes/manifests/*
```

### Kubernetes Issues

**Pods stuck in Pending state**

Check resource availability:

```bash
kubectl describe nodes
kubectl get resourcequota
```

Verify that you have sufficient resources and proper storage classes configured.

**Services not accessible via LoadBalancer**

1. Verify MetalLB is running:
   ```bash
   kubectl get pods -n metallb-system
   ```

2. Check MetalLB configuration:
   ```bash
   kubectl get ipaddresspools -n metallb-system
   kubectl get l2advertisements -n metallb-system
   ```

## Debugging Steps

### 1. Check Terraform State

```bash
cd terraform
terraform show
terraform state list
```

### 2. Verify VM Creation

Log into your Proxmox web interface and verify that the VMs were created with the expected specifications.

### 3. Check VM Connectivity

Test SSH connectivity to each VM:

```bash
ssh ubuntu@<vm-ip-address>
```

### 4. Examine Kubernetes Nodes

```bash
kubectl get nodes -o wide
kubectl describe nodes
```

### 5. Check Pod Status

```bash
kubectl get pods --all-namespaces -o wide
kubectl get events --all-namespaces
```

### 6. Review Logs

For specific pods:

```bash
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> -c <container-name>
```

## Reset Procedures

If you need to completely reset your deployment:

### Reset Kubernetes Cluster

On each node:

```bash
sudo kubeadm reset
sudo systemctl stop kubelet
sudo rm -rf /etc/kubernetes/manifests/*
sudo rm -rf /var/lib/etcd/
sudo systemctl start kubelet
```

### Destroy Infrastructure

```bash
cd terraform
terraform destroy
```

## Support Resources

- Check the GitHub issues page for known issues
- Review the official documentation
- Join our community forums for assistance
```

**Step 5: Make deploy.sh executable and commit all changes**
```bash
chmod +x scripts/deploy.sh
git add .
git commit -m "Finalize deployment script and documentation for Twinbox framework"
```

## Verification and Testing

### Task 11: Create Testing Framework

**Files:**
- Create: `twinbox/tests/smoke-test.sh`
- Create: `twinbox/tests/integration-test.sh`
- Create: `twinbox/tests/validate-cluster.sh`

**Step 1: Create smoke test**
```bash
#!/bin/bash
# Smoke test to verify basic cluster functionality

set -e

echo "Running smoke test..."

# Test 1: Check if kubectl is accessible
if ! command -v kubectl &> /dev/null; then
    echo "FAIL: kubectl is not installed or not in PATH"
    exit 1
fi

# Test 2: Check if cluster is responsive
echo "Checking cluster status..."
kubectl cluster-info || { echo "FAIL: Cannot connect to cluster"; exit 1; }

# Test 3: Check node status
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
if [ "$NODE_COUNT" -eq 0 ]; then
    echo "FAIL: No nodes found in cluster"
    exit 1
fi

READY_NODES=$(kubectl get nodes --no-headers | grep -c Ready)
if [ "$READY_NODES" -ne "$NODE_COUNT" ]; then
    echo "FAIL: Not all nodes are ready ($READY_NODES/$NODE_COUNT ready)"
    exit 1
fi

echo "PASS: All $NODE_COUNT nodes are ready"

# Test 4: Check system pods
SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers | wc -l)
READY_SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers | grep -c Running)

if [ "$READY_SYSTEM_PODS" -lt $(("$SYSTEM_PODS" - 2)) ]; then  # Allow 2 failed pods max
    echo "WARN: Not all system pods are running ($READY_SYSTEM_PODS/$SYSTEM_PODS running)"
else
    echo "PASS: System pods are running"
fi

# Test 5: Deploy a test pod
echo "Deploying test pod..."
kubectl run test-pod --image=nginx:latest --restart=Never --rm -it --image-pull-policy=IfNotPresent --overrides='{"apiVersion":"v1", "spec":{"nodeName":"'"$(kubectl get nodes --no-headers -o jsonpath='{.items[0].metadata.name}')"'}}' -- sleep 5 || { echo "FAIL: Could not deploy test pod"; exit 1; }

echo "PASS: Test pod deployed successfully"

echo "All smoke tests passed!"
```

**Step 2: Create validation script**
```bash
#!/bin/bash
# Validation script to check cluster components

set -e

echo "Validating cluster components..."

# Check if essential services are running
ESSENTIAL_NAMESPACES=("kube-system" "monitoring" "authentik")
for ns in "${ESSENTIAL_NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
        echo "PASS: Namespace $ns exists"
    else
        echo "FAIL: Namespace $ns does not exist"
        exit 1
    fi
done

# Check if essential pods are running
ESSENTIAL_LABELS=(
    "component=etcd"
    "component=kube-apiserver" 
    "component=kube-controller-manager"
    "component=kube-scheduler"
    "k8s-app=kube-dns"
    "app=prometheus"
    "app=alertmanager"
    "app.kubernetes.io/name=grafana"
    "app=authentik-server"
)

for label in "${ESSENTIAL_LABELS[@]}"; do
    NAMESPACE="kube-system"
    if [[ "$label" == *"prometheus"* ]] || [[ "$label" == *"alertmanager"* ]] || [[ "$label" == *"grafana"* ]]; then
        NAMESPACE="monitoring"
    elif [[ "$label" == *"authentik"* ]]; then
        NAMESPACE="authentik"
    fi
    
    COUNT=$(kubectl get pods -n "$NAMESPACE" -l "$label" --no-headers 2>/dev/null | wc -l)
    READY=$(kubectl get pods -n "$NAMESPACE" -l "$label" --no-headers 2>/dev/null | grep -c Running)
    
    if [ "$COUNT" -gt 0 ] && [ "$READY" -eq "$COUNT" ]; then
        echo "PASS: All pods with label '$label' in namespace '$NAMESPACE' are running ($READY/$COUNT)"
    else
        echo "FAIL: Not all pods with label '$label' in namespace '$NAMESPACE' are running ($READY/$COUNT)"
    fi
done

# Check if LoadBalancer services have IPs assigned
LOADBALANCER_SVCS=$(kubectl get svc --all-namespaces -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | .metadata.namespace + "/" + .metadata.name')
for svc in $LOADBALANCER_SVCS; do
    NS=$(echo "$svc" | cut -d'/' -f1)
    NAME=$(echo "$svc" | cut -d'/' -f2)
    EXTERNAL_IP=$(kubectl get svc "$NAME" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -n "$EXTERNAL_IP" ]; then
        echo "PASS: Service $svc has external IP $EXTERNAL_IP"
    else
        echo "INFO: Service $svc does not yet have an external IP (still provisioning)"
    fi
done

echo "Cluster validation complete!"
```

**Step 3: Create integration test**
```bash
#!/bin/bash
# Integration test to verify cross-component functionality

set -e

echo "Running integration tests..."

# Test 1: Verify network connectivity between pods
kubectl run connectivity-test --image=busybox --restart=Never --rm -it -- wget -qO- http://kubernetes.default.svc.cluster.local || { echo "FAIL: Cannot reach kubernetes service"; exit 1; }
echo "PASS: Internal service connectivity works"

# Test 2: Verify storage provisioning
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

sleep 10

PVC_STATUS=$(kubectl get pvc test-pvc -o jsonpath='{.status.phase}')
if [ "$PVC_STATUS" = "Bound" ]; then
    echo "PASS: PVC was bound successfully"
else
    echo "FAIL: PVC was not bound (status: $PVC_STATUS)"
    kubectl delete pvc test-pvc
    exit 1
fi

kubectl delete pvc test-pvc
echo "PASS: Storage provisioning works"

# Test 3: Verify ingress functionality
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-ingress-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-ingress
  template:
    metadata:
      labels:
        app: test-ingress
    spec:
      containers:
      - name: app
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: test-ingress-service
  namespace: default
spec:
  selector:
    app: test-ingress
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  namespace: default
spec:
  rules:
  - host: test.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: test-ingress-service
            port:
              number: 80
EOF

sleep 30

INGRESS_IP=$(kubectl get ingress test-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -n "$INGRESS_IP" ]; then
    echo "PASS: Ingress controller assigned IP $INGRESS_IP"
else
    echo "INFO: Ingress controller still provisioning IP"
fi

kubectl delete ingress test-ingress
kubectl delete service test-ingress-service
kubectl delete deployment test-ingress-app

echo "Integration tests completed!"
```

**Step 4: Make test scripts executable and commit**
```bash
chmod +x tests/*.sh
git add .
git commit -m "Add testing framework with smoke, validation, and integration tests"
```

## Summary

This comprehensive implementation plan covers all phases of the Twinbox Kubernetes-Proxmox framework:

1. **Phase 1**: Core infrastructure setup with Terraform and basic Ansible roles
2. **Phase 2**: Enhanced features including CNI, load balancing, and ingress
3. **Phase 3**: Production hardening with security and monitoring
4. **Phase 4**: Private cloud foundation with user management

The plan includes:
- Complete file structures with all necessary configurations
- Step-by-step implementation tasks with bite-sized chunks
- Testing and validation procedures
- Documentation for getting started, configuration, and troubleshooting
- Modular architecture supporting the Terraform-first approach

This implementation follows the design principles outlined in the original specification, providing a solid foundation for a full private cloud SaaS platform.