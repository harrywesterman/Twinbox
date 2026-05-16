# Before You Begin

Before you run Twinbox, make sure you have a Proxmox host ready and a rough
idea of the hardware you want to dedicate to the cluster.

## What you need

- A Proxmox environment with virtualization support
- Enough free resources for the Management VM and the future Talos nodes
- A browser you can use to reach the Management VM web wizard
- The screenshots in this guide are there to help you recognize each step

## What happens next

The installation has two distinct phases:

1. A bootstrap step on the Proxmox host creates the Management VM.
2. The Management VM serves the web wizard that finishes the cluster setup.

