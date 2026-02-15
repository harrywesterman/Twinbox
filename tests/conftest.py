"""
Pytest configuration and shared fixtures for Twinbox tests.
"""

import pytest
from sqlalchemy.orm import Session
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from manager.shared.database import Base, Database
from manager.shared.models import Cluster, Deployment, Job, VMPlan, DeploymentLog
from manager.shared.proxmox import ProxmoxAPI


@pytest.fixture(scope="session")
def test_engine():
    """Create a test database engine (SQLite in-memory)."""
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool
    )
    Base.metadata.create_all(bind=engine)
    yield engine
    Base.metadata.drop_all(bind=engine)


@pytest.fixture(scope="function")
def test_db_session(test_engine):
    """Create a fresh database session for each test."""
    connection = test_engine.connect()
    transaction = connection.begin()

    session = Session(bind=connection)
    session.begin_nested()

    yield session

    session.rollback()
    session.close()
    transaction.rollback()
    connection.close()


@pytest.fixture
def test_db(test_db_session):
    """Create a Database instance bound to test session."""
    db = Database("sqlite:///:memory:")
    db.engine = test_db_session.bind
    db.SessionLocal = test_db_session.bind.sessionmaker(bind=test_db_session.bind)
    yield db


@pytest.fixture
def mock_proxmox_api():
    """Create a mock Proxmox API client."""
    api = Mock(spec=ProxmoxAPI)
    api.host = "proxmox-test"
    api.user = "root@pam"
    api.base_url = "https://proxmox-test:8006/api2/json"

    # Mock methods
    api.authenticate = Mock(return_value=None)
    api.list_nodes = Mock(return_value=[
        {'node': 'pve1', 'status': 'online'},
        {'node': 'pve2', 'status': 'online'},
        {'node': 'pve3', 'status': 'online'}
    ])
    api.get_node_resources = Mock(return_value={
        'cpu': 0.1,
        'memory': {'used': 1024, 'total': 32768},
        'rootfs': {'used': 100000000000, 'total': 1000000000000}
    })
    api.create_vm = Mock(return_value={'vmid': 100})
    api.start_vm = Mock(return_value={})
    api.stop_vm = Mock(return_value={})
    api.delete_vm = Mock(return_value={})
    api.get_vm_status = Mock(return_value={'status': 'running'})
    api.get_vm_ip = Mock(return_value="192.168.1.100")
    api.wait_for_vm_ip = Mock(return_value="192.168.1.100")
    api.close = Mock()
    api._get_headers = Mock(return_value={
        'Cookie': 'PVEAuthCookie=mock',
        'CSRFPreventionToken': 'CSRF=mock'
    })

    return api


@pytest.fixture
def fake_config():
    """Provide a fake cluster configuration."""
    return {
        'name': 'test-cluster',
        'description': 'Test cluster',
        'management': {
            'cpu': 4,
            'memory_gb': 8.0,
            'disk_gb': 50.0
        },
        'controlplane': {
            'count': 3,
            'cpu': 2,
            'memory_gb': 4.0,
            'disk_gb': 20.0
        },
        'workers': {
            'count': 3,
            'cpu': 2,
            'memory_gb': 4.0,
            'disk_gb': 20.0
        },
        'network': {
            'base': '192.168.1',
            'start_ip': 100,
            'dhcp': False
        }
    }


@pytest.fixture
def sample_nodes():
    """Provide sample Proxmox node data."""
    return [
        {
            'node': 'pve1',
            'total_cpu': 16,
            'total_memory': 128 * 1024,
            'total_disk': 2000 * 1024**3,
            'used_cpu': 2,
            'used_memory': 16 * 1024,
            'used_disk': 200 * 1024**3,
        },
        {
            'node': 'pve2',
            'total_cpu': 16,
            'total_memory': 128 * 1024,
            'total_disk': 2000 * 1024**3,
            'used_cpu': 4,
            'used_memory': 32 * 1024,
            'used_disk': 300 * 1024**3,
        },
        {
            'node': 'pve3',
            'total_cpu': 16,
            'total_memory': 128 * 1024,
            'total_disk': 2000 * 1024**3,
            'used_cpu': 1,
            'used_memory': 8 * 1024,
            'used_disk': 100 * 1024**3,
        }
    ]


@pytest.fixture
def populated_cluster(test_db_session, fake_config):
    """Create a cluster with deployments and nodes in the database."""
    cluster = Cluster(
        name=fake_config['name'],
        description=fake_config['description'],
        status='deployed',
        config=fake_config
    )
    test_db_session.add(cluster)
    test_db_session.flush()  # Get ID

    # Add a deployment
    deployment = Deployment(
        cluster_id=cluster.id,
        task_type='deploy_cluster',
        status='succeeded',
        started_at='2026-02-15 10:00:00',
        completed_at='2026-02-15 10:30:00'
    )
    test_db_session.add(deployment)
    test_db_session.flush()

    # Add some jobs
    jobs = [
        Job(deployment_id=deployment.id, job_type='create_cluster', status='succeeded'),
        Job(deployment_id=deployment.id, job_type='provision_vm', status='succeeded'),
        Job(deployment_id=deployment.id, job_type='configure_talos', status='succeeded'),
        Job(deployment_id=deployment.id, job_type='bootstrap_k8s', status='succeeded'),
    ]
    test_db_session.add_all(jobs)

    # Add VM plans
    vm_plans = [
        VMPlan(
            cluster_id=cluster.id,
            vm_name='twinbox-mgmt-1',
            role='management',
            target_node='pve1',
            cpu=4,
            ram_mb=8192,
            disk_gb=50,
            ip_address='192.168.1.100',
            mac_address='00:16:3e:xx:xx:01',
            bridge='vmbr0'
        ),
        VMPlan(
            cluster_id=cluster.id,
            vm_name='talos-cp-1',
            role='controlplane',
            target_node='pve2',
            cpu=2,
            ram_mb=4096,
            disk_gb=20,
            ip_address='192.168.1.101',
            mac_address='00:16:3e:xx:xx:02',
            bridge='vmbr0'
        ),
        VMPlan(
            cluster_id=cluster.id,
            vm_name='talos-worker-1',
            role='worker',
            target_node='pve3',
            cpu=2,
            ram_mb=4096,
            disk_gb=20,
            ip_address='192.168.1.102',
            mac_address='00:16:3e:xx:xx:03',
            bridge='vmbr0'
        ),
    ]
    test_db_session.add_all(vm_plans)

    # Add some logs
    logs = [
        DeploymentLog(deployment_id=deployment.id, level='INFO', message='Deployment started'),
        DeploymentLog(deployment_id=deployment.id, level='INFO', message='Cluster created'),
        DeploymentLog(deployment_id=deployment.id, level='INFO', message='VMs provisioned'),
        DeploymentLog(deployment_id=deployment.id, level='INFO', message='K8s bootstrapped'),
        DeploymentLog(deployment_id=deployment.id, level='INFO', message='Deployment completed'),
    ]
    test_db_session.add_all(logs)

    test_db_session.commit()

    return {
        'cluster': cluster,
        'deployment': deployment,
        'jobs': jobs,
        'vm_plans': vm_plans,
        'logs': logs
    }


from unittest.mock import Mock
