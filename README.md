# Twinbox

**Simplified Kubernetes on Proxmox**

A one-command, web-driven deployment of production-ready Kubernetes clusters on Proxmox VE.

## Quick Start

On your Proxmox console:

```bash
bash <(curl -s https://raw.githubusercontent.com/your-org/twinbox/main/wizard/setup-wizard.sh)
```

Then open your browser to `http://<management-vm-ip>:8080` and follow the web wizard.

## What You Get

- **Talos Linux** nodes (immutable, secure Kubernetes OS)
- **Kubernetes** cluster with Calico CNI
- **MetalLB** for load balancing
- **Traefik** ingress controller
- **Web UI** for easy management

Zero manual configuration. Just answer a few questions and click "Deploy".

## Architecture

- **Phase 1**: Single bash script creates a Management VM on Proxmox
- **Phase 2**: Web GUI on Management VM auto-deploys complete cluster with intelligent resource discovery and placement

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

## Documentation

- [Architecture Guide](docs/ARCHITECTURE.md)
- [Simplified Design](docs/plans/2026-02-15-twinbox-simplified-design.md)
- [Wizard README](wizard/README.md)
- [Manager README](manager/README.md)

## License

MIT
