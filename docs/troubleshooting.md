# Troubleshooting

## Docker Source Mismatch on Management VM

Symptoms:

- `docker compose` missing
- Docker packages come from Ubuntu `docker.io`

Fix:

```bash
sudo apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

## GHCR Pull Fails

Because packages are public, no login should be required. Check:

```bash
docker pull ghcr.io/harrywesterman/twinbox-manager-api:latest
docker pull ghcr.io/harrywesterman/twinbox-manager-worker:latest
docker pull ghcr.io/harrywesterman/twinbox-manager-web:latest
```

If this fails, verify image names/tags and package visibility in GitHub package settings.

## UI Cannot Reach API

```bash
docker compose ps
docker compose logs manager-api --tail=200
docker compose logs manager-web --tail=200
```

## Worker Not Processing Jobs

```bash
docker compose logs manager-worker --tail=200
ls -la manager-data/queue/pending
ls -la manager-data/queue/running
```

## Worker Job Fails Immediately

The worker image includes required runtime tools (`bash`, `jq`, `tofu`, `talosctl`, `kubectl`, `helm`) and enforces tool versions at startup.

- `talosctl`, `tofu`, `kubectl`, and `helm` are checked against `config/pinned-defaults.sh`

If jobs fail immediately, first check worker startup logs for a version mismatch:

```bash
docker compose pull manager-worker
docker compose up -d manager-worker
docker compose logs manager-worker --tail=200
```

If you see `tool version mismatch`, either:

1. Update `config/pinned-defaults.sh` so the worker image and runtime checks agree, or
2. Switch `TWINBOX_IMAGE_TAG` to an image tag built with your desired tool versions.

## Worker Fails With x86-64-v2 Error

If logs contain:

`This program can only be run on AMD64 processors with v2 microarchitecture support.`

Then the management VM CPU type is too old for recent `talosctl` builds.

Fix:

```bash
# On Proxmox host, set Management VM CPU to host (or x86-64-v2-AES) and cold reboot.
qm set <management-vmid> --cpu host
qm stop <management-vmid>
qm start <management-vmid>
```

Verify inside management VM:

```bash
grep -m1 '^flags' /proc/cpuinfo | egrep -o 'ssse3|sse4_1|sse4_2|popcnt|cx16|lahf_lm' | xargs echo
```

Then restart worker:

```bash
docker compose up -d manager-worker
docker compose logs manager-worker --tail=200
```

## Proxmox Auth Errors

- Validate `.env`: `PROXMOX_HOST`, `PROXMOX_PORT`, `PROXMOX_USER`, `PROXMOX_PASSWORD`.
- Verify Management VM network path to `https://<proxmox-host>:8006`.
- If `provision-nodes` fails on `cluster/status` with 403, the Proxmox service account needs `Sys.Audit` on `/` in addition to the node and storage ACLs.

## Talos Bootstrap Failures

- Verify control-plane IP list passed to bootstrap endpoint.
- Ensure Talos nodes are reachable from Management VM.
- Validate `talosctl` version compatibility with target Talos release.

## Cilium Bootstrap or CoreDNS Failures

Symptoms:

- `provision-nodes` hangs waiting for Cilium or CoreDNS
- `kubectl -n kube-system rollout status daemonset/cilium` never completes
- CoreDNS remains `ContainerCreating`
- CoreDNS events report `FailedCreatePodSandBox`
- Cilium agent logs show `panic: Start or stop failed to finish on time`

Fix:

- Check whether the rendered Cilium manifest was built with the cluster VIP/API endpoint rather than `localhost:7445`
- Verify the Talos machine config includes `cluster.network.cni.name: none` and `cluster.proxy.disabled: true`
- Verify `machine.features.kubePrism.enabled: true` and `machine.features.kubePrism.port: 7445`
- Verify `machine.features.hostDNS.forwardKubeDNSToHost: false`
- Inspect the rendered manifest under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`
- Check `kubectl -n kube-system logs daemonset/cilium` and `kubectl -n kube-system logs deployment/cilium-operator`
- If Cilium still crashes after the endpoint is corrected, compare the pinned chart version against the next supported Cilium release before considering a cluster rebuild
