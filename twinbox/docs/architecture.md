# Twinbox Architecture

## Overview

Twinbox implements a modular architecture that separates infrastructure provisioning from cluster configuration. This approach provides flexibility, maintainability, and clear separation of concerns between infrastructure and application layers.

## Architecture Components

### 1. Infrastructure Layer (Terraform)

The infrastructure layer handles all Proxmox-specific operations:

#### VM Provisioning
- Creates master and worker VMs based on configurable parameters
- Allocates CPU, memory, and storage resources
- Establishes network connectivity through Proxmox bridges
- Clones from a base Ubuntu template for consistency

#### Resource Management
- Manages VM lifecycle (creation, deletion, modification)
- Handles storage allocation on specified pools
- Configures network interfaces and connectivity
- Tracks resource utilization and constraints

### 2. Configuration Layer (Ansible)

The configuration layer manages Kubernetes cluster setup and service deployment:

#### Prerequisites Setup
- Installs required packages and dependencies
- Configures system settings for Kubernetes compatibility
- Sets up container runtime (containerd)
- Performs security hardening

#### Cluster Initialization
- Initializes the Kubernetes cluster with kubeadm
- Configures the control plane on master nodes
- Joins worker nodes to the cluster
- Validates cluster connectivity and functionality

#### Service Deployment
- Installs and configures CNI plugins for networking
- Deploys load balancer (MetalLB)
- Sets up ingress controllers
- Installs monitoring and logging stacks

### 3. Service Stack

#### Networking
- **CNI Plugin**: Provides pod-to-pod networking (Calico or Cilium)
- **Load Balancer**: MetalLB for external service exposure
- **Ingress Controller**: NGINX for HTTP/HTTPS routing

#### Security
- **RBAC**: Role-based access control configuration
- **Network Policies**: Traffic restriction between namespaces
- **Authentication**: Integration with Authentik for identity management
- **Authorization**: Fine-grained access controls

#### Observability
- **Metrics**: Prometheus for metric collection
- **Visualization**: Grafana for dashboard creation
- **Alerting**: AlertManager for notification handling
- **Logging**: Aggregated log collection and analysis

## Deployment Workflow

### Phase 1: Infrastructure Provisioning
1. **Validation**: Checks for required tools and permissions
2. **Planning**: Generates Terraform execution plan
3. **Approval**: Prompts for user confirmation
4. **Execution**: Creates VMs according to specifications
5. **Output**: Generates IP addresses and node information

### Phase 2: Inventory Generation
1. **Data Collection**: Gathers VM IP addresses and metadata
2. **Inventory Creation**: Updates Ansible inventory with node details
3. **Group Assignment**: Categorizes nodes as masters or workers
4. **Connection Setup**: Configures SSH access for Ansible

### Phase 3: Cluster Configuration
1. **Prerequisites**: Installs Kubernetes dependencies
2. **Runtime Setup**: Configures container runtime
3. **Cluster Init**: Initializes Kubernetes cluster
4. **CNI Installation**: Sets up networking
5. **Addons**: Deploys additional services
6. **Monitoring**: Installs observability stack

### Phase 4: Post-Deployment
1. **Kubeconfig**: Copies admin configuration to user location
2. **Validation**: Verifies cluster functionality
3. **Documentation**: Provides access instructions
4. **Cleanup**: Removes temporary files

## Component Interactions

### Terraform to Ansible Integration
- Terraform outputs VM metadata (IPs, names)
- Deployment script transforms outputs into Ansible inventory
- Ansible uses inventory for targeted configuration

### Kubernetes Component Dependencies
- Kubelet depends on container runtime
- API server requires etcd and PKI certificates
- CNI plugin must be installed before workloads
- Ingress controller requires CNI and LoadBalancer

### Service Dependencies
- Monitoring stack requires persistent storage
- Authentik needs DNS resolution and ingress
- Load balancer needs available IP ranges
- Applications depend on service mesh configuration

## Security Considerations

### Infrastructure Security
- SSH key authentication for node access
- Network isolation through Proxmox configuration
- VM resource limits to prevent resource exhaustion

### Kubernetes Security
- RBAC for access control
- Network policies for traffic restriction
- Secure communication with TLS encryption
- Regular security updates and patching

### Data Protection
- Encrypted communication channels
- Secure storage for sensitive data
- Backup and recovery procedures
- Audit logging for compliance

## Scalability Patterns

### Vertical Scaling
- Increase CPU and memory for existing nodes
- Expand storage capacity
- Upgrade network bandwidth

### Horizontal Scaling
- Add more worker nodes
- Distribute workloads across nodes
- Auto-scaling based on resource utilization

## Maintenance Operations

### Routine Maintenance
- Health checks and monitoring
- Log rotation and cleanup
- Certificate renewal
- Backup verification

### Upgrades
- Kubernetes version upgrades
- Component version updates
- Security patching
- Configuration updates

## Troubleshooting Strategy

### Infrastructure Issues
- VM connectivity problems
- Resource allocation failures
- Network configuration errors
- Storage provisioning issues

### Kubernetes Issues
- Node registration failures
- Pod scheduling problems
- Service discovery issues
- Network connectivity problems

### Service Issues
- Addon deployment failures
- Monitoring pipeline disruptions
- Authentication problems
- Performance bottlenecks