# Twinbox Proxmox Console Wizard Guide

This guide explains how to use the interactive console wizard to bootstrap your Twinbox Kubernetes cluster directly from your Proxmox VE server.

## Prerequisites

- Access to your Proxmox VE server via SSH or the Console (Shell).
- Root privileges (`root` user).
- Internet access on the Proxmox server (to download ISOs).
- Sufficient resources (RAM, CPU, and Disk) for your desired cluster size.

## Quick Start (One-Line Command)

You can run the wizard directly from GitHub using `curl` and `bash`. Use the following command in your Proxmox shell:

```bash
bash <(curl -s https://raw.githubusercontent.com/your-org/twinbox/main/wizard/setup-wizard.sh)
```

*(Note: Replace `your-org/twinbox` with the actual repository path once published)*

## Manual Usage

Alternatively, you can clone the repository or copy the script manually:

1.  **Download the script:**
    ```bash
    wget https://raw.githubusercontent.com/your-org/twinbox/main/wizard/setup-wizard.sh
    ```

2.  **Make it executable:**
    ```bash
    chmod +x setup-wizard.sh
    ```

3.  **Run the wizard:**
    ```bash
    ./setup-wizard.sh
    ```

## Wizard Steps

The interactive wizard will guide you through the following steps:

1.  **Cluster Configuration:**
    - Name your cluster.
    - Select the number of Control Plane and Worker nodes.
    - Choose the starting VM ID (e.g., 200) to avoid conflicts.

2.  **Resource Allocation:**
    - Assign RAM, CPU cores, and Disk size for each node.

3.  **Network Configuration:**
    - Specify the Proxmox Bridge interface (default: `vmbr0`).
    - Set the Cluster VIP (Virtual IP) and starting IP address for nodes.

4.  **Confirmation & Installation:**
    - Review your settings and confirm to start the installation.
    - The script will automatically:
        - Download the Talos Linux ISO.
        - Install `talosctl` (if missing).
        - Create the requested VMs with the correct configuration.

## Post-Installation

Once the wizard completes, your VMs will be created.

1.  **Start VMs**: Go to the Proxmox GUI and start your new VMs.
2.  **Generate Config**: On your local workstation (not the Proxmox host), use `talosctl` to generate your cluster configuration:
    ```bash
    talosctl gen config twinbox-cluster https://<VIP_IP>:6443
    ```
3.  **Bootstrap**: Apply the configuration to your nodes to finish bootstrapping the cluster.
