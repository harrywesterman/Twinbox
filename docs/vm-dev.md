# VM Development Workflow

Use this workflow when the Twinbox Management VM is your primary development machine.

## Goal

- Code runs on the Management VM.
- You edit remotely over SSH.
- You debug frontend in your local browser via SSH port forwarding.

## Prerequisites

- Management VM is created by `wizard/setup-wizard.sh`.
- You can SSH into the VM with your SSH key:

```bash
ssh ubuntu@<management-vm-ip>
```

## One-Time Bootstrap on the VM

Run this on the Management VM:

```bash
cd /opt/twinbox
bash scripts/bootstrap-vm.sh
```

What it does:

- Ensures required tools exist (`git`, `docker`, `docker compose`).
- Ensures the repo exists at `/opt/twinbox`.
- Updates to latest `main`.
- Ensures `.env` exists.
- Starts the stack with `docker compose up -d --build`.

## Daily Development Flow

On the VM:

```bash
cd /opt/twinbox
git checkout main
git pull --ff-only
git checkout -b codex/<feature-name>
docker compose up -d
```

After changes:

```bash
docker compose logs -f manager-api manager-web
# run tests for changed parts
git add .
git commit -m "feat: <summary>"
```

## Frontend Debugging from Your Local Machine

Create an SSH tunnel from your local machine:

```bash
ssh -L 3000:localhost:3000 -L 8080:localhost:8080 ubuntu@<management-vm-ip>
```

Then open locally:

- Web UI: `http://localhost:3000`
- API health: `http://localhost:8080/api/health`

Use normal local browser DevTools for frontend debugging.

## Recommended Editor Setup

- Use an editor with Remote SSH support (for example VS Code Remote - SSH).
- Open `/opt/twinbox` on the VM as your workspace.
- Keep Docker/runtime on VM; keep browser/DevTools local.

## Troubleshooting

If Docker access fails:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

If services fail to start:

```bash
cd /opt/twinbox
docker compose ps
docker compose logs --tail=200 manager-api manager-web manager-worker
```
