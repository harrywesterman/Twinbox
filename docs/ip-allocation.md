# IP Allocation

Twinbox automatically suggests and validates IP addresses for Talos cluster nodes.

## How It Works

The `manager-api` server detects network defaults from the Management VM and scans for free IP ranges. The UI calls `GET /api/ip-suggestions` to populate the provision form.

### Detection

From the Management VM, the API reads:

- **Prefix length** — from `ip addr show scope global`, matching the Management VM IP
- **Gateway IP** — from `ip route` default gateway; falls back to `<subnet>.1`
- **DNS servers** — from `/etc/resolv.conf` nameservers (filters out loopback)
- **DNS domain** — from `/etc/resolv.conf` search/domain directive

### VMID Allocation

The API finds a consecutive block of free VMIDs:

1. Queries Proxmox for used VMIDs (`pvesh`, `qm list`, or REST API fallback)
2. Scans from VMID 100 upward for a free block matching the node count
3. Returns `{ start_vmid, vmid_block }`

### IP Suggestion

The `selectSuggestedIpAllocation` function in `lib/ip-allocation.js`:

1. Starts scanning from the Management VM's `/24` subnet
2. Probes each candidate IP with `ping` to check availability
3. Finds a free range for `node_count` consecutive IPs
4. Ensures the VIP IP does not overlap with node IPs
5. Returns `{ start_ip, vip_ip, suggested_ips }`

### Validation

When the user submits the provision form, `POST /api/steps/provision-nodes/execute` validates:

- VMID block is free (no overlap with existing Proxmox VMs)
- VIP IP and start IP are in the same `/24` subnet
- VIP IP does not overlap with the node IP range
- No node IP is already in use (ping probe)
- Node IP range does not exceed the `/24` subnet boundary

## API Endpoint

```
GET /api/ip-suggestions?management_ip=<ip>&node_count=<n>
```

### Response

```json
{
  "management_ip": "192.168.1.50",
  "node_count": 3,
  "name_suggestion": "twinbox-cluster",
  "start_vmid": 110,
  "vmid_block": [110, 111, 112],
  "start_ip": "192.168.1.51",
  "vip_ip": "192.168.1.54",
  "suggested_ips": ["192.168.1.51", "192.168.1.52", "192.168.1.53"],
  "node_prefix_length": 24,
  "gateway_ip": "192.168.1.1",
  "dns_servers": ["1.1.1.1", "8.8.8.8"],
  "dns_domain": "home.lan",
  "probed_addresses": 5
}
```

## Configuration

| Env Variable | Purpose |
|---|---|
| `MANAGER_API_IP_BIN` | Override `ip` binary path (default: `ip`) |
| `MANAGER_API_PING_BIN` | Override `ping` binary path (default: `ping`) |
| `MANAGER_API_RESOLV_CONF` | Override resolv.conf path (default: `/etc/resolv.conf`) |
| `MANAGEMENT_VM_IP` | Management VM IP used as the scan anchor |
