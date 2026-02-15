# Twinbox Manager

The backend component of Twinbox - a comprehensive infrastructure automation platform for deploying and managing Talos Linux Kubernetes clusters on Proxmox VE.

## Architecture

The `manager/` directory contains the core backend services:

```
manager/
├── alembic/          # Database migrations
│   ├── versions/     # Individual migration scripts
│   ├── env.py        # Alembic environment configuration
│   └── script.py.mako # Template for migration scripts
├── shared/           # Shared modules and utilities
│   ├── database.py   # Database connection and session management
│   ├── models.py     # SQLAlchemy ORM models
│   ├── k8s.py        # Kubernetes/Talos operations (planned)
│   ├── placement.py  # VM placement engine (planned)
│   ├── proxmox.py    # Proxmox API client (planned)
│   └── ...
├── web/              # FastAPI web application
│   ├── api/          # REST API endpoints
│   ├── services/     # Business logic layer
│   ├── templates/    # Jinja2 templates
│   └── static/       # Static assets
├── worker/           # Background worker (RQ/Celery)
│   ├── tasks.py      # Background job definitions
│   └── worker.py     # Worker initialization
├── scripts/          # Deployment and utility scripts
├── init/             # Initialization scripts
└── docker-compose.yml # Local development
```

## Database Layer

### Configuration

The database layer uses **SQLAlchemy** with **PostgreSQL** dialect.

- **Engine**: Configured in `shared/database.py` with connection pooling
- **Session**: `SessionLocal` factory for creating database sessions
- **Base**: Declarative base class for ORM models
- **Migrations**: Managed by Alembic in `alembic/`

### Models

All database models are defined in `shared/models.py`:

- **Cluster**: Kubernetes cluster configuration and metadata
- **VMPlan**: VM resource specifications (memory, CPU, disk)
- **Deployment**: Deployment operations and status tracking
- **Job**: Background task queue and execution tracking
- **DeploymentLog**: Structured log entries for deployments
- **ClusterState**: Cached cluster state snapshots

### Getting Started

#### 1. Set up environment variables

```bash
cp .env.example .env
# Edit .env with your configuration
```

Required variables:
- `DATABASE_URL`: PostgreSQL connection string
- `SECRET_KEY`: Application secret for sessions/JWT
- `PROXMOX_CREDENTIALS_PATH`: Path to Proxmox credentials file

#### 2. Install dependencies

```bash
# As part of the overall project
pip install -r requirements.txt
# Or specifically for manager:
pip install sqlalchemy alembic psycopg2-binary
```

#### 3. Initialize database

Using Alembic:
```bash
alembic upgrade head
```

Or directly (for development only):
```bash
python -c "from manager.shared.database import init_db; init_db()"
```

#### 4. Run migrations

```bash
# Generate new migration after model changes
alembic revision --autogenerate -m "Description of changes"

# Apply migrations
alembic upgrade head

# Rollback one step
alembic downgrade -1
```

#### 5. Run the web application

```bash
uvicorn manager.web.main:app --reload --host 0.0.0.0 --port 8000
```

#### 6. Run the worker

```bash
rq worker twinbox-high twinbox-low twinbox-default
# or with Celery:
celery -A manager.worker worker --loglevel=info
```

### Database Schema

#### Cluster

Represents a Kubernetes cluster deployment.

```python
Cluster(
    id: UUID (primary key)
    name: str
    status: str  # pending, provisioning, ready, error, deleting
    talos_version: str
    kubernetes_version: str
    pod_cidr: str
    service_cidr: str
    endpoint: str
    kubeconfig_encrypted: str
    created_at: datetime
    updated_at: datetime
)
```

#### VMPlan

Defines VM resource allocations for a cluster.

```python
VMPlan(
    id: UUID (primary key)
    cluster_id: UUID (FK to clusters)
    role: str  # 'control-plane' or 'worker'
    node_count: int
    memory_mb: int
    cores: int
    disk_gb: int
    proxmox_node: str
    vm_template: str
    network_bridge: str
    storage: str
    extra_config: dict
)
```

#### Deployment

Tracks a deployment operation lifecycle.

```python
Deployment(
    id: UUID (primary key)
    cluster_id: UUID (FK to clusters)
    version: str
    status: str  # pending, running, success, failed, cancelled
    deployment_type: str  # create, update, delete, reset
    progress: float  # 0-100
    current_step: str
    error_message: str
    started_at: datetime
    completed_at: datetime
)
```

#### Job

Background task in the job queue.

```python
Job(
    id: UUID (primary key)
    deployment_id: UUID (FK to deployments)
    task_name: str
    status: str  # pending, running, success, failed, retry
    priority: int
    args: dict
    result: dict
    error: str
    max_retries: int
    retry_count: int
    queued_at: datetime
    started_at: datetime
    completed_at: datetime
)
```

#### DeploymentLog

Structured log entries for a deployment.

```python
DeploymentLog(
    id: UUID (primary key)
    deployment_id: UUID (FK to deployments)
    level: str  # DEBUG, INFO, WARNING, ERROR
    message: str
    context: dict
    timestamp: datetime
)
```

#### ClusterState

Cached snapshot of cluster health and metrics.

```python
ClusterState(
    id: UUID (primary key)
    cluster_id: UUID (FK to clusters)
    captured_at: datetime
    node_count: int
    ready_node_count: int
    pod_count: int
    running_pod_count: int
    kubernetes_version: str
    operating_system: str
    architecture: str
    nodes: dict
    health_score: float  # 0-100
    cpu_total: float
    cpu_used: float
    memory_total_mb: float
    memory_used_mb: float
    disk_total_gb: float
    disk_used_gb: float
)
```

### Database Session Management

Use the `get_db()` dependency in FastAPI endpoints:

```python
from manager.shared.database import get_db
from sqlalchemy.orm import Session

@app.get("/clusters")
def list_clusters(db: Session = Depends(get_db)):
    clusters = db.query(Cluster).all()
    return clusters
```

#### Manual Session Usage

```python
from manager.shared.database import SessionLocal
from manager.shared.models import Cluster

db = SessionLocal()
try:
    cluster = db.query(Cluster).filter_by(id=cluster_id).first()
    # ... do work ...
    db.commit()
except:
    db.rollback()
    raise
finally:
    db.close()
```

### Indexes and Constraints

The schema includes:
- **Primary keys**: All tables use UUID primary keys
- **Foreign keys**: CASCADE delete on cluster relationships
- **Unique constraints**: Cluster name, VMPlan cluster+role
- **Check constraints**: Value ranges (progress 0-100, non-negative counts)
- **Indexes**: Performance-optimized queries on status, timestamps, foreign keys

### Migrations

#### Creating a new migration

1. Update models in `shared/models.py`
2. Ensure `shared/models.py` is imported in `alembic/env.py`
3. Run:
   ```bash
   alembic revision --autogenerate -m "Description"
   ```
4. Review the generated migration in `alembic/versions/`
5. Apply:
   ```bash
   alembic upgrade head
   ```

#### Manual migration

If autogenerate misses changes, create a manual migration:

```python
# alembic/versions/xxx_manual_migration.py
def upgrade():
    op.add_column('clusters', sa.Column('new_field', sa.String(255)))

def downgrade():
    op.drop_column('clusters', 'new_field')
```

### Development Setup

#### Using Docker Compose

```bash
# Start PostgreSQL and Redis
docker-compose up -d postgres redis

# Apply migrations
alembic upgrade head

# Run the application
uvicorn manager.web.main:app --reload
```

#### Direct PostgreSQL Setup

```sql
CREATE DATABASE twinbox;
CREATE USER twinbox WITH PASSWORD 'your_password';
GRANT ALL PRIVILEGES ON DATABASE twinbox TO twinbox;
\c twinbox
```

### Testing

Run unit tests for models and database:

```bash
pytest tests/unit/test_models.py
pytest tests/unit/test_database.py
```

Integration tests with real database:

```bash
pytest tests/integration/test_clusters.py -v
```

## Seeding Sample Data

For development/testing:

```bash
python -c "
from manager.shared.database import SessionLocal, Base, engine
from manager.shared.models import Cluster, VMPlan
from datetime import datetime

Base.metadata.create_all(bind=engine)
db = SessionLocal()

cluster = Cluster(
    name='dev-cluster',
    status='ready',
    pod_cidr='10.244.0.0/16',
    service_cidr='10.96.0.0/12'
)
db.add(cluster)
db.commit()
db.close()
"
```

## Best Practices

1. **Always use sessions as context managers**:
   ```python
   with SessionLocal() as db:
       # work with db
   ```

2. **Handle exceptions with rollback**:
   ```python
   try:
       db.commit()
   except:
       db.rollback()
       raise
   ```

3. **Never hardcode connection strings**: Use `.env` and environment variables

4. **Use UUIDs for primary keys**: Prevents enumeration attacks

5. **Encrypt sensitive data**: Use `kubeconfig_encrypted` for kubeconfigs

6. **Timestamp with timezone**: Always use `DateTime(timezone=True)`

7. **Keep migrations in version control**: Share with team via git

## Troubleshooting

### Connection errors
- Check PostgreSQL is running: `sudo systemctl status postgresql`
- Verify `DATABASE_URL` is correct
- Test connection: `psql $DATABASE_URL`

### Migration conflicts
- If multiple branches have migrations, use: `alembic merge heads -m "merge"`
- Resolve conflicts manually in the generated migration file

### Slow queries
- Check indexes exist: `\d+ clusters` in psql
- Analyze query plans: `EXPLAIN ANALYZE SELECT ...`
- Add missing indexes as needed

### UUID generation
PostgreSQL 13+: Use `gen_random_uuid()` for cryptographically random UUIDs:
```python
sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text('gen_random_uuid()'))
```

Older versions: Use `uuid4()` from Python's uuid module as default

## Contributing

When adding new models:

1. Define the model in `shared/models.py` with:
   - Proper types and constraints
   - Relationships with `back_populates`
   - Indexes in `__table_args__`
   - Docstrings

2. Add appropriate `__repr__` methods for debugging

3. Update this README with new model documentation

4. Create and apply a new Alembic migration

5. Add unit tests for the model in `tests/unit/`

## License

See the main LICENSE file in the repository root.
