"""
Integration tests for deployment workflow.

Tests cover:
- Full deployment flow: create cluster, start deployment, enqueue tasks, execute tasks
- State transitions: cluster status pending -> deployed, deployment status queued -> running -> succeeded
- Log verification
- Error scenarios: task failure -> deployment failed, cluster not deployed
- Idempotency: re-running completed tasks should skip
"""

import pytest
import time
from datetime import datetime
from unittest.mock import Mock, patch, MagicMock
from sqlalchemy.orm import Session
from redis import Redis

from manager.shared.database import Database, Base
from manager.shared.models import (
    Cluster, Deployment, Job, Node, DeploymentLog,
    ClusterStatus, DeploymentStatus, JobType
)

# Note: In a real setup, these would be imported from the worker module
# For testing, we'll create mocks or simple implementations


class MockRQQueue:
    """Mock RQ queue for testing."""

    def __init__(self):
        self.jobs = []
        self.worker = None

    def enqueue(self, func, *args, **kwargs):
        """Mock enqueue - store job info."""
        job = Mock()
        job.func = func
        job.args = args
        job.kwargs = kwargs
        job.id = f"job-{len(self.jobs)}"
        job.status = "queued"
        job.result = None
        job.exc_info = None
        self.jobs.append(job)
        return job

    def get_job(self, job_id):
        """Get job by ID."""
        for job in self.jobs:
            if job.id == job_id:
                return job
        return None

    def work(self, max_jobs=1):
        """Process jobs (mock worker)."""
        for job in self.jobs[:max_jobs]:
            if job.status == "queued":
                try:
                    job.status = "started"
                    result = job.func(*job.args, **job.kwargs)
                    job.status = "finished"
                    job.result = result
                except Exception as e:
                    job.status = "failed"
                    job.exc_info = str(e)


class FakeDeploymentTasks:
    """
    Fake deployment task functions mimicking RQ worker tasks.
    These would normally be in worker/tasks.py
    """

    def __init__(self, db: Database, proxmox_api=None, should_fail=False):
        self.db = db
        self.proxmox_api = proxmox_api
        self.should_fail = should_fail
        self.attempted_jobs = []

    def create_cluster_task(self, cluster_id: int) -> dict:
        """Task: Create cluster record (initial setup)."""
        self.attempted_jobs.append(('create_cluster', cluster_id))

        if self.should_fail:
            raise Exception("Simulated create_cluster failure")

        session = self.db.get_session_sync()
        try:
            cluster = session.query(Cluster).filter_by(id=cluster_id).first()
            if not cluster:
                raise ValueError(f"Cluster {cluster_id} not found")

            # Update cluster status
            cluster.status = ClusterStatus.DEPLOYING
            session.commit()

            # Log
            log = DeploymentLog(deployment_id=None, level="INFO", message="Cluster creation task completed")
            session.add(log)
            session.commit()

            return {"status": "success", "cluster_id": cluster_id}
        finally:
            session.close()

    def provision_vm_task(self, vm_spec: dict, node_name: str) -> dict:
        """Task: Provision a VM on Proxmox."""
        self.attempted_jobs.append(('provision_vm', vm_spec['name'], node_name))

        if self.should_fail:
            raise Exception(f"Simulated provision_vm failure for {vm_spec['name']}")

        if self.proxmox_api:
            # Would actually create VM
            vm_id = vm_spec.get('vm_id', 100)
            result = self.proxmox_api.create_vm(
                node_name=node_name,
                vmid=vm_id,
                name=vm_spec['name'],
                cores=vm_spec['cpu'],
                memory=vm_spec['memory_mb'],
                disk=f"{vm_spec['disk_gb']}G"
            )
        else:
            # Mock - pretend it succeeded
            result = {"vmid": vm_spec.get('vm_id', 100)}

        return {"status": "success", **result}

    def configure_talos_task(self, vm_id: int, cluster_config: dict) -> dict:
        """Task: Configure Talos on a node."""
        self.attempted_jobs.append(('configure_talos', vm_id))

        if self.should_fail:
            raise Exception(f"Simulated configure_talos failure for VM {vm_id}")

        # Mock talosctl configuration
        return {"status": "success", "vm_id": vm_id, "configured": True}

    def bootstrap_k8s_task(self, controlplane_ips: list) -> dict:
        """Task: Bootstrap Kubernetes cluster."""
        self.attempted_jobs.append(('bootstrap_k8s', controlplane_ips))

        if self.should_fail:
            raise Exception("Simulated bootstrap_k8s failure")

        # Mock kubectl/talosctl bootstrap
        return {"status": "success", "kubeconfig": "fake-kubeconfig", "cluster_name": "test"}

    def install_addons_task(self, kubeconfig: str) -> dict:
        """Task: Install cluster addons."""
        self.attempted_jobs.append(('install_addons', kubeconfig))

        if self.should_fail:
            raise Exception("Simulated install_addons failure")

        # Mock helm/ansible installations
        return {"status": "success", "installed": ["traefik", "ceph", "argocd"]}

    def health_check_task(self, cluster_id: int) -> dict:
        """Task: Perform health check."""
        self.attempted_jobs.append(('health_check', cluster_id))

        if self.should_fail:
            raise Exception("Simulated health_check failure")

        # Mock kubectl cluster-info
        return {"status": "healthy", "nodes": 3, "pods": 10}

    def complete_deployment(self, cluster_id: int, success: bool = True, error: str = None) -> dict:
        """Task: Mark deployment as complete."""
        self.attempted_jobs.append(('complete_deployment', cluster_id, success))

        session = self.db.get_session_sync()
        try:
            cluster = session.query(Cluster).filter_by(id=cluster_id).first()
            if cluster:
                cluster.status = ClusterStatus.DEPLOYED if success else ClusterStatus.FAILED
                session.commit()
        finally:
            session.close()

        return {"status": "completed", "success": success}


@pytest.fixture
def test_db():
    """Create an in-memory test database."""
    db = Database("sqlite:///:memory:")
    Base.metadata.create_all(bind=db.engine)
    yield db
    Base.metadata.drop_all(bind=db.engine)
    db.close()


@pytest.fixture
def session(test_db):
    """Create a database session."""
    session = test_db.SessionLocal()
    try:
        yield session
        session.rollback()
    finally:
        session.close()


@pytest.fixture
def mock_proxmox_api():
    """Create a mock Proxmox API client."""
    api = Mock()
    api.create_vm = Mock(return_value={"vmid": 100})
    api.start_vm = Mock(return_value={})
    api.get_vm_ip = Mock(return_value="192.168.1.100")
    return api


@pytest.fixture
def fake_tasks(test_db, mock_proxmox_api):
    """Create fake task handlers."""
    return FakeDeploymentTasks(test_db, mock_proxmox_api)


class TestDeploymentFlow:
    """Integration tests for deployment workflow."""

    def test_full_successful_deployment(self, test_db, session, fake_tasks):
        """Test complete successful deployment flow."""
        # Step 1: Create cluster record
        cluster = Cluster(
            name="test-cluster",
            description="Integration test cluster",
            status=ClusterStatus.PENDING,
            config={
                "management_cpu": 4,
                "management_memory_gb": 8.0,
                "num_controlplane": 3,
                "num_workers": 3,
                "network": {"base": "192.168.1", "dhcp": False}
            }
        )
        session.add(cluster)
        session.commit()

        cluster_id = cluster.id

        # Step 2: Create deployment record
        deployment = Deployment(
            cluster_id=cluster_id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.QUEUED
        )
        session.add(deployment)
        session.commit()

        deployment_id = deployment.id

        # Step 3: Create and execute jobs in order

        # Job 1: create_cluster
        job1 = Job(
            deployment_id=deployment_id,
            job_type=JobType.CREATE_CLUSTER,
            status=DeploymentStatus.QUEUED
        )
        session.add(job1)
        session.commit()

        # Execute job 1
        result1 = fake_tasks.create_cluster_task(cluster_id)
        assert result1["status"] == "success"

        # Update job status
        job1.status = DeploymentStatus.SUCCEEDED
        job1.started_at = datetime.utcnow()
        job1.completed_at = datetime.utcnow()
        session.commit()

        # Job 2: provision_vm (management) - would be multiple of these
        job2 = Job(
            deployment_id=deployment_id,
            job_type=JobType.PROVISION_VM,
            status=DeploymentStatus.QUEUED,
            task_data={"vm_name": "management", "node": "pve1", "vm_spec": {"cpu": 4, "memory_gb": 8, "disk_gb": 50}}
        )
        session.add(job2)
        session.commit()

        result2 = fake_tasks.provision_vm_task(
            job2.task_data["vm_spec"],
            job2.task_data["node"]
        )
        assert result2["status"] == "success"

        job2.status = DeploymentStatus.SUCCEEDED
        job2.started_at = datetime.utcnow()
        job2.completed_at = datetime.utcnow()
        session.commit()

        # Job 3: configure_talos (would be for each node)
        job3 = Job(
            deployment_id=deployment_id,
            job_type=JobType.CONFIGURE_TALOS,
            status=DeploymentStatus.QUEUED,
            task_data={"vm_id": 100, "cluster_config": cluster.config}
        )
        session.add(job3)
        session.commit()

        result3 = fake_tasks.configure_talos_task(100, cluster.config)
        assert result3["status"] == "success"

        job3.status = DeploymentStatus.SUCCEEDED
        job3.started_at = datetime.utcnow()
        job3.completed_at = datetime.utcnow()
        session.commit()

        # Job 4: bootstrap_k8s
        job4 = Job(
            deployment_id=deployment_id,
            job_type=JobType.BOOTSTRAP_K8S,
            status=DeploymentStatus.QUEUED,
            task_data={"controlplane_ips": ["192.168.1.10"]}
        )
        session.add(job4)
        session.commit()

        result4 = fake_tasks.bootstrap_k8s_task(["192.168.1.10"])
        assert result4["status"] == "success"

        job4.status = DeploymentStatus.SUCCEEDED
        job4.started_at = datetime.utcnow()
        job4.completed_at = datetime.utcnow()
        session.commit()

        # Job 5: install_addons
        job5 = Job(
            deployment_id=deployment_id,
            job_type=JobType.INSTALL_ADDONS,
            status=DeploymentStatus.QUEUED,
            task_data={"kubeconfig": "fake-kubeconfig"}
        )
        session.add(job5)
        session.commit()

        result5 = fake_tasks.install_addons_task("fake-kubeconfig")
        assert result5["status"] == "success"

        job5.status = DeploymentStatus.SUCCEEDED
        job5.started_at = datetime.utcnow()
        job5.completed_at = datetime.utcnow()
        session.commit()

        # Job 6: health_check
        job6 = Job(
            deployment_id=deployment_id,
            job_type=JobType.HEALTH_CHECK,
            status=DeploymentStatus.QUEUED,
            task_data={"cluster_id": cluster_id}
        )
        session.add(job6)
        session.commit()

        result6 = fake_tasks.health_check_task(cluster_id)
        assert result6["status"] == "healthy"

        job6.status = DeploymentStatus.SUCCEEDED
        job6.started_at = datetime.utcnow()
        job6.completed_at = datetime.utcnow()
        session.commit()

        # Mark deployment complete
        deployment.status = DeploymentStatus.SUCCEEDED
        deployment.started_at = job1.started_at
        deployment.completed_at = job6.completed_at
        session.commit()

        # Final: complete deployment
        fake_tasks.complete_deployment(cluster_id, success=True)

        # Reload cluster
        session.refresh(cluster)
        assert cluster.status == ClusterStatus.DEPLOYED

        # Verify all jobs succeeded
        jobs = session.query(Job).filter_by(deployment_id=deployment_id).all()
        for job in jobs:
            assert job.status == DeploymentStatus.SUCCEEDED

        # Verify deployment succeeded
        session.refresh(deployment)
        assert deployment.status == DeploymentStatus.SUCCEEDED
        assert deployment.started_at is not None
        assert deployment.completed_at is not None

        # Verify logs exist
        logs = session.query(DeploymentLog).filter_by(deployment_id=deployment_id).all()
        # At least the one we manually added
        assert len(logs) >= 1

    def test_deployment_with_failure(self, test_db, session, fake_tasks):
        """Test deployment that fails at one step."""
        # Create cluster
        cluster = Cluster(
            name="fail-test-cluster",
            status=ClusterStatus.PENDING,
            config={}
        )
        session.add(cluster)
        session.commit()

        # Create deployment
        deployment = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.RUNNING
        )
        session.add(deployment)
        session.commit()

        deployment_id = deployment.id

        # First job succeeds
        job1 = Job(deployment_id=deployment_id, job_type=JobType.CREATE_CLUSTER, status=DeploymentStatus.SUCCEEDED)
        session.add(job1)
        session.commit()

        # Second job fails
        job2 = Job(
            deployment_id=deployment_id,
            job_type=JobType.PROVISION_VM,
            status=DeploymentStatus.FAILED,
            error_message="Proxmox resource exhausted"
        )
        session.add(job2)
        session.commit()

        # Simulate failing tasks
        fake_tasks.should_fail = True

        # Try to execute job2
        with pytest.raises(Exception, match="Simulated provision_vm failure"):
            fake_tasks.provision_vm_task({"name": "test"}, "node1")

        # Deployment should be marked as failed
        deployment.status = DeploymentStatus.FAILED
        deployment.error_message = "Proxmox resource exhausted"
        deployment.error_details = {"failed_job": job2.id}
        session.commit()

        # Cluster should not be deployed
        cluster.status = ClusterStatus.FAILED
        session.commit()

        # Verify state
        session.refresh(deployment)
        assert deployment.status == DeploymentStatus.FAILED
        assert deployment.error_message is not None

        session.refresh(cluster)
        assert cluster.status == ClusterStatus.FAILED

    def test_idempotent_task_retry(self, test_db, session, fake_tasks):
        """Test that re-running a completed task skips or returns cached result."""
        # Create cluster and deployment
        cluster = Cluster(name="idempotent-test", status=ClusterStatus.DEPLOYED, config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.SUCCEEDED
        )
        session.add(deployment)
        session.commit()

        # Create a completed job
        job = Job(
            deployment_id=deployment.id,
            job_type=JobType.HEALTH_CHECK,
            status=DeploymentStatus.SUCCEEDED,
            result={"status": "healthy"}
        )
        session.add(job)
        session.commit()

        # Simulate task retry - check job status before running
        job_check = session.query(Job).filter_by(id=job.id).first()

        # In real implementation, worker would check job status
        if job_check.status == DeploymentStatus.SUCCEEDED:
            # Should skip running the task again
            assert job_check.result["status"] == "healthy"
            # Would return cached result
        else:
            pytest.fail("Job should already be succeeded")

    def test_multiple_deployments_same_cluster(self, test_db, session):
        """Test multiple deployments for same cluster (e.g., updates)."""
        cluster = Cluster(name="multi-deploy", status=ClusterStatus.DEPLOYED, config={})
        session.add(cluster)
        session.commit()

        # First deployment
        deploy1 = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.SUCCEEDED,
            completed_at=datetime.utcnow()
        )
        session.add(deploy1)
        session.commit()

        # Second deployment (update)
        deploy2 = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.SUCCEEDED,
            started_at=datetime.utcnow(),
            completed_at=datetime.utcnow()
        )
        session.add(deploy2)
        session.commit()

        # Verify both exist
        deployments = session.query(Deployment).filter_by(cluster_id=cluster.id).all()
        assert len(deployments) == 2
        assert all(d.status == DeploymentStatus.SUCCEEDED for d in deployments)

    def test_deployment_with_job_dependencies(self, test_db, session):
        """Test jobs with explicit dependencies."""
        cluster = Cluster(name="dep-test", status=ClusterStatus.DEPLOYING, config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.RUNNING
        )
        session.add(deployment)
        session.commit()

        # Job 1: provision VMs (no deps)
        job1 = Job(
            deployment_id=deployment.id,
            job_type=JobType.PROVISION_VM,
            status=DeploymentStatus.QUEUED,
            depends_on=[]
        )
        session.add(job1)
        session.commit()

        # Job 2: configure Talos (depends on job1)
        job2 = Job(
            deployment_id=deployment.id,
            job_type=JobType.CONFIGURE_TALOS,
            status=DeploymentStatus.QUEUED,
            depends_on=[job1.id]
        )
        session.add(job2)
        session.commit()

        # Worker logic: check dependencies before starting
        job2_deps = session.query(Job).filter(Job.id.in_(job2.depends_on)).all()
        assert len(job2_deps) == 1
        assert job2_deps[0].id == job1.id

        # Job 2 should not start until job1 succeeds
        assert job1.status == DeploymentStatus.QUEUED
        assert job2.status == DeploymentStatus.QUEUED

        # Complete job1
        job1.status = DeploymentStatus.SUCCEEDED
        session.commit()

        # Now job2 can start
        job2.status = DeploymentStatus.RUNNING
        session.commit()

        session.refresh(job2)
        assert job2.status == DeploymentStatus.RUNNING

    def test_log_retrieval_ordered(self, test_db, session):
        """Test that logs are retrieved in chronological order."""
        cluster = Cluster(name="log-order-test", status=ClusterStatus.DEPLOYING, config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.RUNNING
        )
        session.add(deployment)
        session.commit()

        # Add multiple logs
        logs = [
            DeploymentLog(deployment_id=deployment.id, level="INFO", message="Started", created_at=datetime.utcnow()),
            DeploymentLog(deployment_id=deployment.id, level="INFO", message="Step 1", created_at=datetime.utcnow()),
            DeploymentLog(deployment_id=deployment.id, level="WARN", message="Warning", created_at=datetime.utcnow()),
            DeploymentLog(deployment_id=deployment.id, level="ERROR", message="Error", created_at=datetime.utcnow()),
            DeploymentLog(deployment_id=deployment.id, level="INFO", message="Completed", created_at=datetime.utcnow()),
        ]

        # Add with slight delays
        import time
        for log in logs:
            session.add(log)
            time.sleep(0.001)  # tiny delay to ensure different timestamps
        session.commit()

        # Retrieve logs ordered by creation time
        retrieved_logs = session.query(DeploymentLog)\
            .filter_by(deployment_id=deployment.id)\
            .order_by(DeploymentLog.created_at)\
            .all()

        assert len(retrieved_logs) == 5
        assert retrieved_logs[0].message == "Started"
        assert retrieved_logs[1].message == "Step 1"
        assert retrieved_logs[2].level == "WARN"
        assert retrieved_logs[3].level == "ERROR"
        assert retrieved_logs[4].message == "Completed"

    def test_cluster_status_transitions(self, test_db, session):
        """Test valid status transitions for cluster."""
        cluster = Cluster(name="status-test", status=ClusterStatus.PENDING, config={})
        session.add(cluster)
        session.commit()

        # Valid: PENDING -> DEPLOYING
        cluster.status = ClusterStatus.DEPLOYING
        session.commit()
        assert cluster.status == ClusterStatus.DEPLOYING

        # Valid: DEPLOYING -> DEPLOYED
        cluster.status = ClusterStatus.DEPLOYED
        session.commit()
        assert cluster.status == ClusterStatus.DEPLOYED

        # Valid: DEPLOYING -> FAILED
        cluster.status = ClusterStatus.FAILED
        session.commit()
        assert cluster.status == ClusterStatus.FAILED

        # Any -> DELETING
        cluster.status = ClusterStatus.DELETING
        session.commit()
        assert cluster.status == ClusterStatus.DELETING

        # Any -> DELETED
        cluster.status = ClusterStatus.DELETED
        session.commit()
        assert cluster.status == ClusterStatus.DELETED

    def test_deployment_status_transitions(self, test_db, session):
        """Test valid status transitions for deployment."""
        cluster = Cluster(name="deploy-status-test", status=ClusterStatus.DEPLOYING, config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.QUEUED
        )
        session.add(deployment)
        session.commit()

        # QUEUED -> RUNNING
        deployment.status = DeploymentStatus.RUNNING
        deployment.started_at = datetime.utcnow()
        session.commit()
        assert deployment.status == DeploymentStatus.RUNNING

        # RUNNING -> SUCCEEDED
        deployment.status = DeploymentStatus.SUCCEEDED
        deployment.completed_at = datetime.utcnow()
        session.commit()
        assert deployment.status == DeploymentStatus.SUCCEEDED

        # RUNNING -> FAILED
        deployment.status = DeploymentStatus.RUNNING
        session.commit()

        deployment.status = DeploymentStatus.FAILED
        deployment.error_message = "Task failed"
        deployment.completed_at = datetime.utcnow()
        session.commit()
        assert deployment.status == DeploymentStatus.FAILED

    def test_job_retry_mechanism(self, test_db, session):
        """Test job retry logic (attempts counter)."""
        cluster = Cluster(name="retry-test", status=ClusterStatus.DEPLOYING, config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.RUNNING
        )
        session.add(deployment)
        session.commit()

        job = Job(
            deployment_id=deployment.id,
            job_type=JobType.PROVISION_VM,
            status=DeploymentStatus.FAILED,
            attempts=1,
            max_attempts=3
        )
        session.add(job)
        session.commit()

        # Simulate retry
        if job.attempts < job.max_attempts:
            job.attempts += 1
            job.status = DeploymentStatus.QUEUED
            session.commit()

        assert job.attempts == 2
        assert job.status == DeploymentStatus.QUEUED

        # Check max attempts reached
        job.attempts = 3
        session.commit()

        if job.attempts >= job.max_attempts:
            job.status = DeploymentStatus.FAILED
            # Should not retry again
        session.commit()

        assert job.attempts == 3
        assert job.status == DeploymentStatus.FAILED

    def test_concurrent_jobs_safety(self, test_db, session):
        """Test that concurrent job execution doesn't create duplicate work."""
        cluster = Cluster(name="concurrent-test", status=ClusterStatus.DEPLOYING, config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.RUNNING
        )
        session.add(deployment)
        session.commit()

        # Simulate multiple workers trying to pick the same job
        job = Job(
            deployment_id=deployment.id,
            job_type=JobType.PROVISION_VM,
            status=DeploymentStatus.QUEUED
        )
        session.add(job)
        session.commit()

        # Worker 1: Query for queued jobs
        jobs = session.query(Job)\
            .filter_by(deployment_id=deployment.id, status=DeploymentStatus.QUEUED)\
            .first()

        # Worker 1 claims the job (update status)
        if jobs:
            jobs.status = DeploymentStatus.RUNNING
            session.commit()
            worker_id = 1
        else:
            worker_id = None

        session.refresh(job)

        # Worker 2: Query again
        jobs2 = session.query(Job)\
            .filter_by(deployment_id=deployment.id, status=DeploymentStatus.QUEUED)\
            .first()

        # Worker 2 should not find the job (it's now running)
        assert jobs2 is None or jobs2.id != job.id

        # The original job should still be marked as running
        assert job.status == DeploymentStatus.RUNNING

    def test_cleanup_on_delete(self, test_db, session):
        """Test that logs are cleaned up when deployment is deleted."""
        cluster = Cluster(name="cleanup-test", status=ClusterStatus.DEPLOYING, config={})
        session.add(cluster)
        session.commit()

        deployment = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.RUNNING
        )
        session.add(deployment)
        session.commit()

        # Add logs
        for i in range(5):
            log = DeploymentLog(deployment_id=deployment.id, level="INFO", message=f"Log {i}")
            session.add(log)
        session.commit()

        log_count_before = session.query(DeploymentLog).filter_by(deployment_id=deployment.id).count()
        assert log_count_before == 5

        # Delete deployment (cascade should delete logs)
        session.delete(deployment)
        session.commit()

        log_count_after = session.query(DeploymentLog).filter_by(deployment_id=deployment.id).count()
        assert log_count_after == 0


class TestEndToEndScenarios:
    """End-to-end scenario tests."""

    def test_deploy_then_redeploy(self, test_db, session, fake_tasks):
        """Test deploying a cluster, then re-deploying (update)."""
        # Initial deployment
        cluster = Cluster(
            name="e2e-cluster",
            status=ClusterStatus.DEPLOYED,
            config={"version": "1.0"}
        )
        session.add(cluster)
        session.commit()

        deployment1 = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.SUCCEEDED,
            completed_at=datetime.utcnow()
        )
        session.add(deployment1)
        session.commit()

        # Update: change config
        cluster.config = {"version": "1.1"}
        session.commit()

        # New deployment
        deployment2 = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.SUCCEEDED,
            started_at=datetime.utcnow(),
            completed_at=datetime.utcnow()
        )
        session.add(deployment2)
        session.commit()

        # Verify cluster is still deployed
        session.refresh(cluster)
        assert cluster.status == ClusterStatus.DEPLOYED

        # Verify two deployments exist
        deployments = session.query(Deployment).filter_by(cluster_id=cluster.id).all()
        assert len(deployments) == 2

    def test_failed_deployment_can_be_retried(self, test_db, session):
        """Test that a failed deployment can be retried."""
        cluster = Cluster(
            name="retry-cluster",
            status=ClusterStatus.FAILED,
            config={}
        )
        session.add(cluster)
        session.commit()

        # Failed deployment
        deploy1 = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.FAILED,
            error_message="Resource exhausted"
        )
        session.add(deploy1)
        session.commit()

        # Retry deployment
        cluster.status = ClusterStatus.PENDING
        session.commit()

        deploy2 = Deployment(
            cluster_id=cluster.id,
            task_type=JobType.DEPLOY_CLUSTER,
            status=DeploymentStatus.RUNNING
        )
        session.add(deploy2)
        session.commit()

        assert cluster.status == ClusterStatus.PENDING
        assert deploy2.status == DeploymentStatus.RUNNING
