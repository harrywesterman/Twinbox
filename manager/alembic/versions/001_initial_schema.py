"""
Initial migration: create all tables and indexes

Revision ID: 001_initial_schema
Revises:
Create Date: 2025-02-15 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '001_initial_schema'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """
    Create all database tables and indexes.

    Creates:
    - clusters
    - vm_plans
    - deployments
    - jobs
    - deployment_logs
    - cluster_states
    """
    # Create clusters table
    op.create_table(
        'clusters',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False, default=sa.text('gen_random_uuid()')),
        sa.Column('name', sa.String(length=255), nullable=False),
        sa.Column('description', sa.Text, nullable=True),
        sa.Column('status', sa.String(length=50), nullable=False, server_default='pending'),
        sa.Column('talos_version', sa.String(length=50), nullable=True),
        sa.Column('kubernetes_version', sa.String(length=50), nullable=True),
        sa.Column('pod_cidr', sa.String(length=50), nullable=False, server_default='10.244.0.0/16'),
        sa.Column('service_cidr', sa.String(length=50), nullable=False, server_default='10.96.0.0/12'),
        sa.Column('endpoint', sa.String(length=255), nullable=True),
        sa.Column('kubeconfig_encrypted', sa.Text, nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('NOW()')),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('NOW()')),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('name', name='uq_cluster_name'),
    )

    # Create indexes for clusters
    op.create_index('ix_clusters_name', 'clusters', ['name'])
    op.create_index('ix_clusters_status_created', 'clusters', ['status', 'created_at'])

    # Create vm_plans table
    op.create_table(
        'vm_plans',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False, default=sa.text('gen_random_uuid()')),
        sa.Column('cluster_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('role', sa.String(length=50), nullable=False),
        sa.Column('node_count', sa.Integer, nullable=False, server_default='1'),
        sa.Column('memory_mb', sa.Integer, nullable=False),
        sa.Column('cores', sa.Integer, nullable=False),
        sa.Column('disk_gb', sa.Integer, nullable=False),
        sa.Column('proxmox_node', sa.String(length=255), nullable=False),
        sa.Column('vm_template', sa.String(length=255), nullable=True),
        sa.Column('network_bridge', sa.String(length=50), nullable=False, server_default='vmbr0'),
        sa.Column('storage', sa.String(length=255), nullable=False),
        sa.Column('extra_config', postgresql.JSONB, nullable=True, server_default='{}'),
        sa.PrimaryKeyConstraint('id'),
        sa.ForeignKeyConstraint(['cluster_id'], ['clusters.id'], ondelete='CASCADE'),
        sa.UniqueConstraint('cluster_id', 'role', name='uq_vmplan_cluster_role'),
        sa.CheckConstraint('node_count > 0', name='ck_vmplan_node_count_positive'),
        sa.CheckConstraint('memory_mb > 0 AND cores > 0 AND disk_gb > 0', name='ck_vmplan_resources_positive'),
    )

    # Create indexes for vm_plans
    op.create_index('ix_vmplans_cluster_id', 'vm_plans', ['cluster_id'])
    op.create_index('ix_vmplans_cluster_role', 'vm_plans', ['cluster_id', 'role'])

    # Create deployments table
    op.create_table(
        'deployments',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False, default=sa.text('gen_random_uuid()')),
        sa.Column('cluster_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('version', sa.String(length=50), nullable=False),
        sa.Column('status', sa.String(length=50), nullable=False, server_default='pending'),
        sa.Column('deployment_type', sa.String(length=50), nullable=False),
        sa.Column('progress', sa.Float, nullable=False, server_default='0.0'),
        sa.Column('current_step', sa.String(length=255), nullable=True),
        sa.Column('error_message', sa.Text, nullable=True),
        sa.Column('started_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('NOW()')),
        sa.Column('completed_at', sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint('id'),
        sa.ForeignKeyConstraint(['cluster_id'], ['clusters.id'], ondelete='CASCADE'),
        sa.CheckConstraint('progress >= 0 AND progress <= 100', name='ck_deployment_progress_range'),
    )

    # Create indexes for deployments
    op.create_index('ix_deployments_cluster_id', 'deployments', ['cluster_id'])
    op.create_index('ix_deployments_status', 'deployments', ['status'])
    op.create_index('ix_deployments_started_at', 'deployments', ['started_at DESC'])

    # Create jobs table
    op.create_table(
        'jobs',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False, default=sa.text('gen_random_uuid()')),
        sa.Column('deployment_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('task_name', sa.String(length=255), nullable=False),
        sa.Column('status', sa.String(length=50), nullable=False, server_default='pending'),
        sa.Column('priority', sa.Integer, nullable=False, server_default='0'),
        sa.Column('args', postgresql.JSONB, nullable=True, server_default='{}'),
        sa.Column('result', postgresql.JSONB, nullable=True),
        sa.Column('error', sa.Text, nullable=True),
        sa.Column('max_retries', sa.Integer, nullable=False, server_default='3'),
        sa.Column('retry_count', sa.Integer, nullable=False, server_default='0'),
        sa.Column('queued_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('NOW()')),
        sa.Column('started_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('completed_at', sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint('id'),
        sa.ForeignKeyConstraint(['deployment_id'], ['deployments.id'], ondelete='CASCADE'),
        sa.CheckConstraint('priority >= 0', name='ck_job_priority_nonnegative'),
        sa.CheckConstraint('retry_count >= 0 AND max_retries >= 0', name='ck_job_retries_nonnegative'),
    )

    # Create indexes for jobs
    op.create_index('ix_jobs_deployment_id', 'jobs', ['deployment_id'])
    op.create_index('ix_jobs_status_priority', 'jobs', ['status', 'priority DESC'])
    op.create_index('ix_jobs_queued_at', 'jobs', ['queued_at'])

    # Create deployment_logs table
    op.create_table(
        'deployment_logs',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False, default=sa.text('gen_random_uuid()')),
        sa.Column('deployment_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('level', sa.String(length=20), nullable=False),
        sa.Column('message', sa.Text, nullable=False),
        sa.Column('context', postgresql.JSONB, nullable=True, server_default='{}'),
        sa.Column('timestamp', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('NOW()')),
        sa.PrimaryKeyConstraint('id'),
        sa.ForeignKeyConstraint(['deployment_id'], ['deployments.id'], ondelete='CASCADE'),
    )

    # Create indexes for deployment_logs
    op.create_index('ix_deployment_logs_deployment_id', 'deployment_logs', ['deployment_id'])
    op.create_index('ix_deployment_logs_timestamp', 'deployment_logs', ['timestamp DESC'])
    op.create_index('ix_deployment_logs_level_timestamp', 'deployment_logs', ['level', 'timestamp DESC'])

    # Create cluster_states table
    op.create_table(
        'cluster_states',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False, default=sa.text('gen_random_uuid()')),
        sa.Column('cluster_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('captured_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.text('NOW()')),
        sa.Column('node_count', sa.Integer, nullable=False, server_default='0'),
        sa.Column('ready_node_count', sa.Integer, nullable=False, server_default='0'),
        sa.Column('pod_count', sa.Integer, nullable=False, server_default='0'),
        sa.Column('running_pod_count', sa.Integer, nullable=False, server_default='0'),
        sa.Column('kubernetes_version', sa.String(length=50), nullable=True),
        sa.Column('operating_system', sa.String(length=100), nullable=True),
        sa.Column('architecture', sa.String(length=50), nullable=True),
        sa.Column('nodes', postgresql.JSONB, nullable=True, server_default='{}'),
        sa.Column('health_score', sa.Float, nullable=True),
        sa.Column('cpu_total', sa.Float, nullable=True),
        sa.Column('cpu_used', sa.Float, nullable=True),
        sa.Column('memory_total_mb', sa.Float, nullable=True),
        sa.Column('memory_used_mb', sa.Float, nullable=True),
        sa.Column('disk_total_gb', sa.Float, nullable=True),
        sa.Column('disk_used_gb', sa.Float, nullable=True),
        sa.PrimaryKeyConstraint('id'),
        sa.ForeignKeyConstraint(['cluster_id'], ['clusters.id'], ondelete='CASCADE'),
        sa.CheckConstraint('node_count >= 0 AND ready_node_count >= 0', name='ck_clusterstate_nodes_nonnegative'),
        sa.CheckConstraint('pod_count >= 0 AND running_pod_count >= 0', name='ck_clusterstate_pods_nonnegative'),
        sa.CheckConstraint('health_score IS NULL OR (health_score >= 0 AND health_score <= 100)', name='ck_clusterstate_health_score_range'),
    )

    # Create indexes for cluster_states
    op.create_index('ix_cluster_states_cluster_captured', 'cluster_states', ['cluster_id', 'captured_at DESC'])
    op.create_index('ix_cluster_states_captured_at', 'cluster_states', ['captured_at DESC'])

    # Create triggers for updated_at on clusters
    op.execute("""
        CREATE OR REPLACE FUNCTION update_updated_at_column()
        RETURNS TRIGGER AS $$
        BEGIN
            NEW.updated_at = NOW();
            RETURN NEW;
        END;
        $$ language 'plpgsql';
    """)

    op.execute("""
        CREATE TRIGGER update_clusters_updated_at
            BEFORE UPDATE ON clusters
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at_column();
    """)


def downgrade() -> None:
    """
    Drop all tables in reverse order to respect foreign key constraints.
    """
    # Drop triggers first
    op.execute("DROP TRIGGER IF EXISTS update_clusters_updated_at ON clusters")
    op.execute("DROP FUNCTION IF EXISTS update_updated_at_column()")

    # Drop tables
    op.drop_table('cluster_states')
    op.drop_table('deployment_logs')
    op.drop_table('jobs')
    op.drop_table('deployments')
    op.drop_table('vm_plans')
    op.drop_table('clusters')
