import { resolveStepPresentation } from './step-presentation.js';

const BASE_STATE = {
  status: 'ready',
  state: {
    status: 'not_started',
    inputs: {},
    outputs: null,
    cluster_id: null,
    error: null,
    updated_at: null,
  },
  latest_job: null,
};

const QUESTION_STEP_DEFS = [
  {
    id: 'provision-nodes',
    title: 'Deploy Talos Cluster',
    type: 'action',
    journey_stage: 'setup',
    order: 10,
    summary: 'Install Talos Linux on separate VMs on the cluster.',
    explanation: 'Talos Linux is the immutable, Kubernetes-focused operating system that Twinbox uses. This page collects the cluster sizing, placement, and network values before the long installation starts.',
    side_help: 'Talos Linux is a minimal, secure, API-driven operating system built specifically for running Kubernetes.',
    inputs: [
      { id: 'scale_percent', label: 'Cluster scale', type: 'integer', required: true, min: 0, max: 100, default: 90, help: 'Scale the VM footprint from 0 to 100 percent. The default reserves room on all three Proxmox hosts.' },
      { id: 'controlplane_count', label: 'Control planes', type: 'integer', required: true, min: 1, max: 15, default: 3, help: 'Current API range is 1 to 15. The default gives each Proxmox host one control plane.' },
      { id: 'worker_count', label: 'Workers', type: 'integer', required: true, min: 0, max: 200, default: 3, help: 'Current API range is 0 to 200. The default gives each Proxmox host one worker.' },
      { id: 'cpu_cores', label: 'CPU cores', type: 'integer', required: true, min: 1, max: 64, default: 4, help: 'Per-node CPU allocation. Use 4 vCPU or more for the standard Twinbox baseline; 2 vCPU is only realistic for a reduced dev/test cluster.' },
      { id: 'memory_mb', label: 'Memory MB', type: 'integer', required: true, min: 512, max: 1048576, default: 8192, help: 'Worker memory allocation. Control planes stay fixed at 4096 MB, while workers keep this slider-driven memory size.' },
      { id: 'bridge', label: 'Bridge', type: 'string', required: true, default: 'vmbr0', help: 'Proxmox bridge for Talos node traffic.' },
      { id: 'start_vmid', label: 'Start VMID', type: 'integer', required: true, min: 100, max: 999999, default: 200, help: 'Seed VMID for the cluster inventory.' },
      { id: 'vip_ip', label: 'VIP IP', type: 'ipv4', required: true, default: '192.168.1.50', help: 'Virtual IP for the Talos control plane.' },
      { id: 'node_prefix_length', label: 'Prefix length', type: 'integer', required: true, min: 1, max: 32, default: 24, help: 'CIDR prefix for Talos node addresses.' },
      { id: 'gateway_ip', label: 'Gateway IP', type: 'ipv4', required: true, default: '192.168.1.1', help: 'Default gateway for Talos nodes.' },
      { id: 'dns_servers', label: 'DNS servers', type: 'string', required: true, default: '1.1.1.1,8.8.8.8', help: 'Comma-separated IPv4 DNS servers for Talos nodes.' },
    ],
  },
  {
    id: 'choose-ingress-route',
    title: 'Choose Ingress Route',
    type: 'config',
    journey_stage: 'setup',
    order: 22,
    summary: 'Choose which ingress branch Twinbox should expose for this cluster.',
    explanation: 'This page records the ingress strategy you want to use and the DNS domain that will back the platform hostnames.',
    side_help: 'Pick one ingress route and enter the base DNS domain you want to use. On Cloudflare Free, Cloudflare Tunnel is shown only for prd clusters.',
    inputs: [
      {
        id: 'ingress_route',
        label: 'Ingress Route',
        type: 'string',
        required: true,
        help: 'Choose the ingress branch you want Twinbox to configure.',
        options: [
          { label: 'Wiredoor', value: 'wiredoor' },
          { label: 'Cloudflare Tunnel', value: 'cloudflare-tunnel' },
          { label: 'MetalLB', value: 'metallb' },
          { label: 'Tailscale', value: 'tailscale' },
        ],
      },
      {
        id: 'dns_domain',
        label: 'DNS Domain',
        type: 'string',
        required: true,
        help: 'Enter the DNS domain for your cluster.',
      },
    ],
  },
  {
    id: 'provision-wiredoor-bastion',
    title: 'Deploy Wiredoor Bastion Host',
    type: 'action',
    journey_stage: 'setup',
    order: 32,
    ingress_route: 'wiredoor',
    summary: 'Provision a Wiredoor bastion host on Hetzner Cloud for external access.',
    explanation: 'This page collects the Hetzner and DNS details needed to create the Wiredoor bastion host.',
    side_help: 'Create a Hetzner Cloud API token with Read & Write permissions in your Hetzner project before continuing.',
    inputs: [
      { id: 'hcloud_token', label: 'Hetzner API Token', type: 'string', required: true, help: 'Your Hetzner Cloud API token. Create one at https://console.hetzner.cloud/' },
      { id: 'hcloud_location', label: 'Server Location', type: 'string', required: false, default: 'fsn1', help: 'Datacenter location: fsn1, nbg1, or hel1.' },
      { id: 'hcloud_server_type', label: 'Server Type', type: 'string', required: false, default: 'cax11', help: 'Server size: cax11 (ARM64, 2vCPU/4GB), cx22 (x86, 2vCPU/4GB).' },
      { id: 'wiredoor_network', label: 'WireGuard Network', type: 'string', required: false, default: '10.200.0.0/24', help: 'Internal WireGuard subnet for the VPN tunnel.' },
      { id: 'zone_name', label: 'Domain Name', type: 'string', required: true, help: 'Your domain name (for example example.com).' },
      { id: 'ssh_public_key', label: 'SSH Public Key', type: 'string', required: false, help: 'Optional: your SSH public key for direct server access.' },
    ],
  },
  {
    id: 'configure-wiredoor-ingress',
    title: 'Configure Wiredoor Ingress',
    type: 'action',
    journey_stage: 'setup',
    order: 34,
    ingress_route: 'wiredoor',
    summary: 'Set up Wiredoor tunnel access to the cluster.',
    explanation: 'This page collects the Wiredoor server details Twinbox will use to register the tunnel.',
    side_help: 'You need the Wiredoor server URL and an API token from that server.',
    inputs: [
      { id: 'wiredoor_url', label: 'Wiredoor Server URL', type: 'string', required: true, help: 'The URL of the Wiredoor server, for example https://wiredoor.example.com.' },
      { id: 'wiredoor_token', label: 'Wiredoor API Token', type: 'string', required: true, help: 'API token for authenticating with the Wiredoor server.' },
      { id: 'wiredoor_node_name', label: 'Wiredoor Node Name', type: 'string', required: false, help: 'Optional custom node name for the Wiredoor tunnel.' },
    ],
  },
  {
    id: 'configure-cloudflare-dns',
    title: 'Configure Cloudflare DNS',
    type: 'action',
    journey_stage: 'setup',
    order: 36,
    ingress_route: 'wiredoor',
    summary: 'Configure DNS records in Cloudflare for the Wiredoor host.',
    explanation: 'This page collects the Cloudflare token and domain needed to create the DNS records for your Wiredoor setup.',
    side_help: 'Create a Cloudflare API token with Zone DNS Edit permissions before continuing.',
    inputs: [
      { id: 'cloudflare_api_token', label: 'Cloudflare API Token', type: 'string', required: true, help: 'API token with Zone DNS Edit permissions.' },
      { id: 'zone_name', label: 'Domain Name', type: 'string', required: true, help: 'Your domain name, for example example.com.' },
    ],
  },
  {
    id: 'configure-cloudflare-tunnel',
    title: 'Configure Cloudflare Tunnel',
    type: 'action',
    journey_stage: 'setup',
    order: 38,
    ingress_route: 'cloudflare-tunnel',
    summary: 'Expose services through a Cloudflare Tunnel.',
    explanation: 'This page collects the Cloudflare account details needed to create or reuse the tunnel and DNS record.',
    side_help: 'Create one Cloudflare custom API token with both Cloudflare Tunnel Edit and DNS Edit permissions.',
    inputs: [
      { id: 'cf_api_token', label: 'Cloudflare API Token', type: 'string', required: true, help: 'One Cloudflare custom token with Tunnel Edit and DNS Edit permissions.' },
      { id: 'cf_account_id', label: 'Cloudflare Account ID', type: 'string', required: true, help: 'Your Cloudflare Account ID, found in the dashboard sidebar.' },
      { id: 'cf_zone_id', label: 'Cloudflare Zone ID', type: 'string', required: true, help: 'Your Cloudflare Zone ID, found in the Overview tab of the zone.' },
    ],
  },
  {
    id: 'configure-metallb-ingress',
    title: 'Configure MetalLB Ingress',
    type: 'action',
    journey_stage: 'setup',
    order: 40,
    ingress_route: 'metallb',
    summary: 'Expose services using MetalLB load balancer with port forwarding.',
    explanation: 'This page collects the LAN IP range and public hostname information MetalLB needs.',
    side_help: 'You need an available MetalLB IP range, a public hostname, and router port forwarding.',
    inputs: [
      { id: 'metallb_ip_range', label: 'MetalLB IP Range', type: 'string', required: true, help: 'IP range for MetalLB to assign, for example 192.168.1.200-192.168.1.210.' },
      { id: 'public_host', label: 'Public Hostname', type: 'string', required: true, help: 'Public hostname pointing to your router.' },
      { id: 'dyndns_provider', label: 'DynDNS Provider', type: 'string', required: false, help: 'DynDNS provider name if using dynamic DNS.' },
      { id: 'dyndns_token', label: 'DynDNS API Token', type: 'string', required: false, help: 'API token for your DynDNS provider.' },
    ],
  },
  {
    id: 'configure-tailscale-ingress',
    title: 'Configure Tailscale Ingress',
    type: 'action',
    journey_stage: 'setup',
    order: 42,
    ingress_route: 'tailscale',
    summary: 'Expose services through a Tailscale tailnet.',
    explanation: 'This page collects the Tailscale or Headscale credentials Twinbox needs to join the cluster to your tailnet.',
    side_help: 'Generate a Tailscale auth key in the admin console, or provide your Headscale URL and API key.',
    inputs: [
      { id: 'ts_authkey', label: 'Tailscale Auth Key', type: 'string', required: true, help: 'Auth key generated from your Tailscale admin console.' },
      { id: 'ts_tag', label: 'Tailscale ACL Tag', type: 'string', required: false, help: 'Optional ACL tag to assign to this node.' },
      { id: 'headscale_url', label: 'Headscale URL', type: 'string', required: false, help: 'URL of your self-hosted Headscale instance.' },
      { id: 'headscale_key', label: 'Headscale API Key', type: 'string', required: false, help: 'API key for your self-hosted Headscale instance.' },
    ],
  },
  {
    id: 'create-users-and-groups',
    title: 'Create Users and Groups',
    type: 'action',
    journey_stage: 'setup',
    order: 44,
    summary: 'Create the first Authentik user and admin group.',
    explanation: 'This page collects the first account details Twinbox will use for Authentik.',
    side_help: 'Use this page to create the account you will use to sign in to Authentik and the protected applications later.',
    inputs: [
      { id: 'full_name', label: 'Full name', type: 'string', required: true, help: 'Display name for the first Authentik user.' },
      { id: 'username', label: 'Login name', type: 'string', required: true, help: 'Authentik username for the first user.' },
      { id: 'email', label: 'Email address', type: 'string', required: false, help: 'Optional email address for account recovery and profile completeness.' },
    ],
  },
];

function decorateStep(step) {
  return {
    ...BASE_STATE,
    ...step,
    ...resolveStepPresentation(step),
  };
}

export function getQuestionSteps(answers = {}) {
  const ingressRoute = answers?.['choose-ingress-route']?.ingress_route || '';

  return QUESTION_STEP_DEFS
    .filter((step) => !step.ingress_route || step.ingress_route === ingressRoute)
    .map(decorateStep);
}
