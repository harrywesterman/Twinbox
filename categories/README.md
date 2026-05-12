# Categories

Manifest-driven step catalog for the Twinbox web wizard. Each category groups related provisioning and configuration steps that the UI presents in order.

## Structure

```
categories/
├── management-vm/
│   ├── category.yaml
│   └── steps/
│       ├── configure-automatic-updates/
│       └── install-k9s/
└── talos-cluster/
    ├── category.yaml
    └── steps/
        ├── provision-nodes/
        ├── install-argocd/
        ├── install-longhorn-storage/
        └── ... (30+ steps)
```

## `category.yaml`

Defines the category metadata:

| Field | Description |
|-------|-------------|
| `id` | Unique identifier |
| `title` | Display name |
| `summary` | Short description |

## `step.yaml`

Each step directory contains a `step.yaml` manifest and a runner script.

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (matches directory name) |
| `title` | Display name |
| `type` | `action` (provision/deploy) or `config` (settings) |
| `journey_stage` | Workflow stage (`setup`, `manage`) |
| `summary` | Short description |
| `explanation` | Detailed explanation for the UI |
| `side_help` | Contextual help text |
| `inputs` | Typed input parameters with labels, defaults, constraints, and help text |
| `secrets.files` | Secret references with `scope`, `item`, `attachment`, `format` |
| `runner.script` | Relative path to the shell script to execute |

## Bundle manifests

Bundle manifests live in `categories/apps/bundles/` and are loaded into the app catalog when the manager API asks for bundle definitions.

| Field | Description |
|-------|-------------|
| `id` | Unique bundle identifier |
| `title` | Display name |
| `summary` | Short description |
| `description` | Optional long-form text explaining the bundles purpose, origin, and included apps. Supports markdown-style formatting (paragraphs separated by blank lines, `**bold**` section headers). |
| `apps` | Array of app step ids that the bundle installs |
| `iconUrl` | Optional bundle artwork |
| `iconAlt` | Optional accessible label for the artwork |

## Categories

### management-vm

Steps for configuring the Management VM itself.

### talos-cluster

Provision Talos infrastructure and bootstrap the cluster in guided steps.

### apps

Standalone applications that can be installed on top of the cluster through the Twinbox Portal.

See [categories/apps/README.md](apps/README.md) for the full app catalog.
