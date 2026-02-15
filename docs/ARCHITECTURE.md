# Twinbox System Architecture

## Overview

Twinbox is an infrastructure orchestration platform that automates the deployment and management of Kubernetes clusters on Proxmox-based infrastructure. The system consists of a manager application with web UI and background worker services, supporting phase-based deployments from initial bootstrap to full production setup.

## Components

### Manager Application

The manager is the core orchestration engine, split into two complementary services:

#### Web Service (`manager/web/`)
- **Framework**: FastAPI with Jinja2 templates
- **Port**: 8080
- **Responsibilities**:
  - User interface for deployment orchestration
  - API endpoints for cluster management
  - Deployment plan generation and review
  - Real-time log streaming via Server-Sent Events (SSE)
  - Credential encryption and secure storage

#### Worker Service (`manager/worker/`)
- **Background Processing**: RQ (Redis Queue)
- **Responsibilities**:
  - Long-running deployment tasks
  - Infrastructure provisioning
  - Configuration generation
  - Terraform execution
  - Ansible playbook orchestration

### Shared Module (`manager/shared/`)
Common utilities used by both services:
- `security.py` - Credential encryption/decryption using Fernet
- `database.py` - SQLAlchemy models and database connection
- `proxmox.py` - Proxmox API client
- `k8s.py` - Kubernetes cluster management
- `placement.py` - VM placement algorithm
- `talos.py` - Talos Linux configuration

### Data Stores

#### PostgreSQL
- Stores deployment plans, cluster state, credentials (encrypted)
- Connection pool managed by SQLAlchemy
- Alembic for schema migrations

#### Redis
- Message queue for RQ worker
- Session storage
- Caching layer

## Deployment Flow

1. **Collection Phase**: User provides infrastructure details via web UI
2. **Plan Generation**: System generates Terraform plans and Talos configurations
3. **Review**: User reviews and approves the deployment plan
4. **Execution**:
   - Web service enqueues tasks to Redis
   - Worker processes tasks sequentially:
     - Provision VMs on Proxmox
     - Apply Terraform configurations
     - Generate Talos configs
     - Bootstrap Kubernetes nodes
     - Install CNI, CSI, and core addons
5. **Completion**: Display results and provide kubeconfig

## Security

- All sensitive credentials encrypted at rest using Fernet symmetric encryption
- SECRET_KEY environment variable required for encryption
- Database connections use SSL when available
- No plaintext credentials stored in logs

## Technology Stack

- **Backend**: Python 3.11, FastAPI, SQLAlchemy
- **Queue**: Redis, RQ
- **Database**: PostgreSQL 15
- **Container**: Docker + Docker Compose
- **IaC**: Terraform, Ansible
- **OS**: Talos Linux, Ubuntu
- **Kubernetes**: k3s on Talos nodes
