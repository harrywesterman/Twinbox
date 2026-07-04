import { resolveStepPresentation } from "./step-presentation.js";

const BASE_STATE = {
  status: "ready",
  state: {
    status: "not_started",
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
    id: "provision-nodes",
    title: "Deploy Talos Cluster",
    type: "action",
    journey_stage: "setup",
    summary: "Install Talos Linux on separate VMs on the cluster.",
    explanation:
      "Talos Linux is the immutable, Kubernetes-focused operating system that Twinbox uses. This page collects the cluster sizing, placement, and network values before the long installation starts.",
    side_help:
      "Talos Linux is a minimal, secure, API-driven operating system built specifically for running Kubernetes.",
    inputs: [
      {
        id: "scale_percent",
        label: "Cluster scale",
        type: "integer",
        required: true,
        min: 0,
        max: 100,
        default: 90,
        help: "Scale the VM footprint from 0 to 100 percent. The default reserves room on all three Proxmox hosts.",
      },
      {
        id: "worker_disk_percent",
        label: "Worker disk",
        type: "integer",
        required: true,
        min: 10,
        max: 100,
        default: 100,
        help: "Set the worker disk size as a share of the free worker-host disk. Twinbox starts at 100 percent of the space shared across the three Proxmox hosts.",
      },
      {
        id: "controlplane_count",
        label: "Control planes",
        type: "integer",
        required: true,
        min: 1,
        max: 15,
        default: 3,
        help: "Current API range is 1 to 15. The default gives each Proxmox host one control plane.",
      },
      {
        id: "worker_count",
        label: "Workers",
        type: "integer",
        required: true,
        min: 0,
        max: 200,
        default: 3,
        help: "Current API range is 0 to 200. The default gives each Proxmox host one worker.",
      },
      {
        id: "cpu_cores",
        label: "CPU cores",
        type: "integer",
        required: true,
        min: 1,
        max: 64,
        default: 4,
        help: "Worker CPU allocation. Control planes stay fixed at 2 vCPU, while workers use this value.",
      },
      {
        id: "memory_mb",
        label: "Memory MB",
        type: "integer",
        required: true,
        min: 512,
        max: 1048576,
        default: 10240,
        help: "Worker memory allocation. Control planes stay fixed at 3072 MB, while workers default to 10240 MB unless you change the slider.",
      },
      {
        id: "bridge",
        label: "Bridge",
        type: "string",
        required: true,
        default: "vmbr0",
        help: "Proxmox bridge for Talos node traffic.",
      },
      {
        id: "start_vmid",
        label: "Start VMID",
        type: "integer",
        required: true,
        min: 100,
        max: 999999,
        default: 200,
        help: "Seed VMID for the cluster inventory.",
      },
      {
        id: "vip_ip",
        label: "VIP IP",
        type: "ipv4",
        required: true,
        default: "",
        help: "Virtual IP for the Talos control plane.",
      },
      {
        id: "node_prefix_length",
        label: "Prefix length",
        type: "integer",
        required: true,
        min: 1,
        max: 32,
        default: "",
        help: "CIDR prefix for Talos node addresses.",
      },
      {
        id: "gateway_ip",
        label: "Gateway IP",
        type: "ipv4",
        required: true,
        default: "",
        help: "Default gateway for Talos nodes.",
      },
      {
        id: "dns_servers",
        label: "DNS servers",
        type: "string",
        required: true,
        default: "1.1.1.1,8.8.8.8",
        help: "Comma-separated IPv4 DNS servers for Talos nodes.",
      },
    ],
  },
  {
    id: "configure-dns",
    title: "Configure DNS Provider",
    type: "config",
    journey_stage: "setup",
    summary: "Enter your DNS provider details so Twinbox can manage DNS records automatically.",
    explanation:
      "Twinbox uses external-dns to create and update DNS records in your provider. Your API token is stored in a Kubernetes Secret in the cluster.",
    side_help:
      "Pick the DNS provider where your domain is registered. Twinbox needs an API token with permission to create DNS records (e.g. Zone DNS Edit for Cloudflare).",
    inputs: [
      {
        id: "dns_domain",
        label: "DNS Domain",
        type: "string",
        required: true,
        help: "Your domain name (e.g. example.com).",
      },
      {
        id: "dns_provider",
        label: "DNS Provider",
        type: "string",
        required: true,
        help: "Choose the DNS provider that hosts your domain.",
        options: [
          { label: "Cloudflare", value: "cloudflare" },
          { label: "AWS Route 53", value: "aws" },
          { label: "DigitalOcean", value: "digitalocean" },
        ],
      },
      {
        id: "dns_api_token",
        label: "API Token / Access Key",
        type: "string",
        required: true,
        help: "API token with DNS zone edit permissions.",
      },
      {
        id: "dns_api_secret",
        label: "API Secret Key (optional)",
        type: "string",
        required: false,
        help: "Only required for AWS (Secret Access Key). Leave empty for Cloudflare, DigitalOcean.",
      },
    ],
  },
  {
    id: "choose-ingress-route",
    title: "Choose Ingress Route",
    type: "config",
    journey_stage: "setup",
    summary: "Choose whether Twinbox should expose this cluster through Cloudflare or NetBird.",
    explanation:
      "This page records the ingress strategy you want to use. The DNS domain was already configured in the previous step.",
    side_help:
      "Pick one ingress route. Cloudflare is shown only for prd clusters. Non-prd clusters use NetBird and keep the slug-prefixed hostname model, so tst with example.com becomes tst.example.com. prd uses hostnames directly under the base domain, such as authentik.example.com.",
    inputs: [
      {
        id: "ingress_route",
        label: "Ingress Route",
        type: "string",
        required: true,
        help: "Choose the ingress branch you want Twinbox to configure. Cloudflare is available only for prd clusters on Cloudflare Free.",
        options: [
          { label: "Cloudflare", value: "cloudflare-tunnel" },
          { label: "NetBird", value: "netbird" },
        ],
      },
    ],
  },
  {
    id: "create-users-and-groups",
    title: "Create Users and Groups",
    type: "action",
    journey_stage: "setup",
    summary: "Create the first Authentik user and admin group.",
    explanation: "This page collects the first account details Twinbox will use for Authentik.",
    side_help:
      "Use this page to create the account you will use to sign in to Authentik and the protected applications later. Twinbox also uses this email for NetBird setup and Let's Encrypt certificate notices.",
    inputs: [
      {
        id: "full_name",
        label: "Full name",
        type: "string",
        required: true,
        help: "Display name for the first Authentik user.",
      },
      {
        id: "username",
        label: "Login name",
        type: "string",
        required: true,
        help: "Authentik username for the first user.",
      },
      {
        id: "email",
        label: "Email address",
        type: "string",
        required: true,
        help: "Email address for account recovery, NetBird setup, and Let's Encrypt certificate notices.",
      },
    ],
  },
  {
    id: "provision-netbird-bastion",
    title: "Deploy NetBird Bastion Host",
    type: "action",
    journey_stage: "setup",
    ingress_route: "netbird",
    summary: "Provision a self-hosted NetBird bastion.",
    explanation:
      "This step provisions or bootstraps a Linux bastion running self-hosted NetBird with the combined NetBird server, dashboard, built-in Traefik, and NetBird Reverse Proxy.",
    side_help:
      "Choose Hetzner for the fully automated VM path, or existing-vm when you already have a clean Debian/Ubuntu VM reachable by SSH from the Management VM. Twinbox uses the DNS provider configured earlier to create NetBird records.",
    inputs: [
      {
        id: "bastion_provider",
        label: "Bastion Provider",
        type: "string",
        required: true,
        default: "hetzner",
        help: "Use hetzner to let Twinbox create the VM, or existing-vm to bootstrap a clean Debian/Ubuntu VM reachable over SSH from the Management VM.",
        options: [
          { label: "Hetzner", value: "hetzner" },
          { label: "Existing VM", value: "existing-vm" },
        ],
      },
      {
        id: "hcloud_token",
        label: "Hetzner API Token",
        type: "string",
        required: false,
        help: "Required only when Bastion Provider is hetzner. Create one at https://console.hetzner.cloud/",
      },
      {
        id: "hcloud_location",
        label: "Server Location",
        type: "string",
        required: false,
        default: "fsn1",
        help: "Datacenter location: fsn1 (Falkenstein), nbg1 (Nürnberg), or hel1 (Helsinki)",
      },
      {
        id: "hcloud_server_type",
        label: "Server Type",
        type: "string",
        required: false,
        default: "cax11",
        help: "Server size: cax11 (ARM64, 2vCPU/4GB), cpx22 (x86, 2vCPU/4GB). Twinbox retries once with cpx22 if cax11 placement is unavailable.",
      },
      {
        id: "existing_bastion_mode",
        label: "Existing VM Mode",
        type: "string",
        required: false,
        default: "cloud-vm",
        help: "Use cloud-vm when the SSH host and public IPv4 are the same public VM. Use local-port-forward when SSH uses a private LAN address and router port forwarding exposes the public IPv4.",
        options: [
          { label: "Cloud VM", value: "cloud-vm" },
          { label: "Local port forwarding", value: "local-port-forward" },
        ],
      },
      {
        id: "existing_bastion_public_ipv4",
        label: "Public IPv4",
        type: "string",
        required: false,
        help: "Required for existing-vm. DNS A records for netbird and wildcard services point to this public IPv4.",
      },
      {
        id: "existing_bastion_ssh_host",
        label: "SSH Host",
        type: "string",
        required: false,
        help: "Required for existing-vm. Hostname or address reachable from the Management VM. Local VM mode may use a private LAN address here.",
      },
      {
        id: "existing_bastion_ssh_port",
        label: "SSH Port",
        type: "string",
        required: false,
        default: "22",
        help: "SSH port reachable from the Management VM. SSH does not need to be publicly forwarded.",
      },
      {
        id: "existing_bastion_ssh_user",
        label: "SSH User",
        type: "string",
        required: false,
        default: "root",
        help: "Existing VM bootstrap supports root SSH only in this version.",
      },
      {
        id: "existing_bastion_ssh_private_key",
        label: "SSH Private Key",
        type: "string",
        required: false,
        help: "Private key used by the Management VM to connect to the existing bastion VM.",
      },
      {
        id: "existing_bastion_os_family",
        label: "OS Family",
        type: "string",
        required: false,
        default: "debian",
        help: "Debian or Ubuntu are supported for existing-vm bootstrap.",
        options: [
          { label: "Debian", value: "debian" },
          { label: "Ubuntu", value: "ubuntu" },
        ],
      },
      {
        id: "existing_bastion_confirm_clean_host",
        label: "Confirm Clean Host",
        type: "string",
        required: false,
        default: "false",
        help: "Set to true to confirm Twinbox may manage /opt/netbird on this dedicated VM. Existing unmanaged NetBird compose files are refused.",
        options: [
          { label: "false", value: "false" },
          { label: "true", value: "true" },
        ],
      },
      {
        id: "existing_bastion_confirm_port_forwarding",
        label: "Confirm Port Forwarding",
        type: "string",
        required: false,
        default: "false",
        help: "Required for local-port-forward mode. Confirm TCP 80/443 and UDP 3478 are forwarded to the VM; add TCP 25 only if Mailu will receive direct mail.",
        options: [
          { label: "false", value: "false" },
          { label: "true", value: "true" },
        ],
      },
    ],
  },
  {
    id: "configure-cloudflare-tunnel",
    title: "Configure Cloudflare Tunnel",
    type: "action",
    journey_stage: "setup",
    ingress_route: "cloudflare-tunnel",
    summary: "Expose services through a Cloudflare Tunnel.",
    explanation:
      "This page collects the Cloudflare account details needed to create or reuse the tunnel and DNS record.",
    side_help:
      "Create one Cloudflare custom API token with both Cloudflare Tunnel Edit and DNS Edit permissions.",
    inputs: [
      {
        id: "cf_api_token",
        label: "Cloudflare API Token",
        type: "string",
        required: true,
        help: "One Cloudflare custom token with Tunnel Edit and DNS Edit permissions.",
      },
      {
        id: "cf_account_id",
        label: "Cloudflare Account ID",
        type: "string",
        required: true,
        help: "Your Cloudflare Account ID, found in the dashboard sidebar.",
      },
      {
        id: "cf_zone_id",
        label: "Cloudflare Zone ID",
        type: "string",
        required: true,
        help: "Your Cloudflare Zone ID, found in the Overview tab of the zone.",
      },
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
  const ingressRoute = answers?.["choose-ingress-route"]?.ingress_route || "";

  return QUESTION_STEP_DEFS.filter(
    (step) => !step.ingress_route || step.ingress_route === ingressRoute
  ).map(decorateStep);
}
