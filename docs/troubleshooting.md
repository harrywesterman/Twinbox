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
docker pull ghcr.io/harrywesterman/twinbox-manager-api:sha-a4275f4
docker pull ghcr.io/harrywesterman/twinbox-manager-worker:sha-a4275f4
docker pull ghcr.io/harrywesterman/twinbox-manager-web:sha-a4275f4
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

- Check the Cilium/Kubernetes compatibility matrix before chasing lower-level datapath bugs; `1.18.x` is not a safe fit for Kubernetes `v1.35.x`
- Check whether the rendered Cilium manifest was built with the cluster VIP/API endpoint rather than `localhost:7445`
- Verify the Talos machine config includes `cluster.network.cni.name: none` and `cluster.proxy.disabled: true`
- Verify `machine.features.kubePrism.enabled: true` and `machine.features.kubePrism.port: 7445`
- Verify `machine.features.hostDNS.forwardKubeDNSToHost: false`
- Inspect the rendered manifest under `/opt/twinbox/bootstrap/secrets/cluster/<cluster-id>/cilium/cilium-bootstrap.yaml`
- Check `kubectl -n kube-system logs daemonset/cilium` and `kubectl -n kube-system logs deployment/cilium-operator`
- If Cilium still crashes after the endpoint is corrected, compare the pinned chart version against the next supported Cilium release before considering a cluster rebuild

## CrowdSec Bouncer Fails

Symptoms:

- Traefik returns 500 errors
- CrowdSec bouncer plugin cannot connect to LAPI
- `kubectl -n crowdsec logs deployment/crowdsec-bouncer` shows auth failures

Fix:

```bash
# Verify the bouncer key exists in OpenBao
kubectl -n crowdsec get externalsecret crowdsec-bouncer-credentials
kubectl -n crowdsec get secret crowdsec-bouncer-credentials -o jsonpath='{.data.CROWDSEC_BOUNCER_KEY}' | base64 -d

# Verify the LAPI is reachable from Traefik
kubectl -n traefik exec deploy/traefik -- wget -qO- http://crowdsec-service.crowdsec.svc.cluster.local:8080
```

If the key is missing, rerun `install-crowdsec` to regenerate and sync it.

## ntfy Not Receiving Alerts

Symptoms:

- Alerts fire in Alertmanager but no push notifications arrive
- ntfy topic returns 404

Fix:

```bash
# Verify ntfy is running
kubectl -n ntfy get pods
kubectl -n ntfy logs deployment/ntfy

# Verify Alertmanager routing
kubectl -n monitoring get configmap alertmanager-config -o yaml | grep ntfy

# Test manually
curl -d "Test message" https://ntfy.<ZONE_NAME>/twinbox-alerts
```

If the topic does not exist, ntfy creates it automatically on first publish. Check that the Alertmanager URL includes the correct topic path.

## NetBird Routing Peers Not Connecting

Symptoms:

- NetBird bastion is reachable but internal services return 502/503
- Routing peer pods show connection errors

Fix:

```bash
# Verify routing peers are running
kubectl -n netbird get pods
kubectl -n netbird logs daemonset/netbird-routing-peers

# Verify the setup key is valid
kubectl -n netbird get externalsecret
kubectl -n netbird get secret netbird-setup-key -o jsonpath='{.data.key}' | base64 -d

# Verify NetBird routes are advertised
talosctl dmesg | grep -i netbird
```

If the setup key is expired, rerun `configure-netbird-ingress` to generate a new one.

## Cloudtty Shell Not Opening

Symptoms:

- Cloudtty UI loads but the terminal stays blank
- CloudShell pod is stuck in Pending

Fix:

```bash
# Verify the operator is running
kubectl -n cloudtty get pods
kubectl -n cloudtty logs deployment/cloudtty-operator

# Verify the CloudShell instance exists
kubectl -n cloudtty get cloudshell

# Check for resource constraints
kubectl -n cloudtty describe pod -l app.kubernetes.io/name=cloudtty
```

If the CloudShell pod is Pending, check whether the cluster has sufficient CPU/memory and whether the NodePort range is open.

## Management Consoles Return 404

Symptoms:

- Proxmox, SeaweedFS, or Longhorn UIs return 404 through Traefik
- Services exist but Endpoints are empty

Fix:

```bash
# Verify Endpoints point at the Management VM IP
kubectl -n traefik get endpoints proxmox seaweedfs
kubectl -n traefik describe endpoints proxmox

# Verify the Management VM IP has not changed
ssh twinbox@<management-vm-ip> 'ip addr show scope global'

# Verify Traefik can reach the Management VM
kubectl -n traefik exec deploy/traefik -- wget -qO- http://<management-vm-ip>:8006
```

If the Management VM IP changed, update the Endpoints or restart `install-management-consoles` to regenerate them.
