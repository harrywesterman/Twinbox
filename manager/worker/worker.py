"""
RQ Worker Entrypoint for Twinbox Deployment System.

This module initializes the RQ worker, sets up database connection, logging,
and registers all deployment task functions. It handles signals for graceful
shutdown and startup.

Usage:
    python -m manager.worker.worker

Or via docker-compose, the worker container runs:
    rq worker --url redis://redis:6379 twinbox
"""

import os
import signal
import sys
import logging
from typing import Any
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

import redis
from rq import Worker, Queue, Connection
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from shared.database import Base, DATABASE_URL, get_db
from shared.models import (
    Cluster,
    Deployment,
    Job,
    DeploymentLog,
    VMPlan,
    ClusterState,
)
from shared.security import encrypt_credentials, decrypt_credentials

# Import task functions (will be defined in tasks.py)
from worker.tasks import (
    discover_proxmox,
    size_vms,
    create_talos_vms,
    wait_for_talos,
    generate_talos_configs,
    apply_talos_config,
    bootstrap_kubernetes,
    wait_for_workers,
    install_cni,
    install_metallb,
    install_traefik,
    deployment_complete,
)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)

# Redis and RQ configuration
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
QUEUE_NAME = "twinbox"

# Database engine (for worker-side operations if needed)
engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def setup_logging_to_db(deployment_id: Any, job_id: Optional[str] = None) -> None:
    """
    Set up a custom logging handler that writes logs to the database.

    Creates a DeploymentLog entry for each log message emitted during task execution.

    Args:
        deployment_id: UUID of the deployment
        job_id: Optional RQ job ID
    """
    class DBHandler(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            try:
                db = SessionLocal()
                log_entry = DeploymentLog(
                    deployment_id=deployment_id,
                    job_id=job_id or "unknown",
                    step=record.__dict__.get("step", "general"),
                    level=record.levelname.lower(),
                    message=record.getMessage(),
                    context={
                        "logger": record.name,
                        "filename": record.filename,
                        "lineno": record.lineno,
                        **record.__dict__.get("context", {}),
                    },
                )
                db.add(log_entry)
                db.commit()
                db.close()
            except Exception as e:
                # Don't let logging failures crash the worker
                sys.stderr.write(f"Failed to write log to DB: {e}\n")

    # Add DB handler to root logger
    root_logger = logging.getLogger()
    root_logger.addHandler(DBHandler())


def get_worker_queues() -> list:
    """
    Get the list of queues this worker should listen to.

    Returns:
        List of Queue objects
    """
    redis_conn = redis.from_url(REDIS_URL)
    return [Queue(QUEUE_NAME, connection=redis_conn)]


def signal_handler(signum: int, frame: Any) -> None:
    """
    Handle termination signals (SIGTERM, SIGINT) for graceful shutdown.

    Args:
        signum: Signal number
        frame: Current stack frame
    """
    logger.info(f"Received signal {signum}, shutting down worker gracefully...")
    sys.exit(0)


def main() -> None:
    """
    Main entrypoint for the RQ worker.

    Initializes database, sets up logging, connects to Redis, and starts
    the worker loop. Registers signal handlers for graceful shutdown.
    """
    logger.info("Starting Twinbox RQ Worker")
    logger.info(f"Redis URL: {REDIS_URL}")
    logger.info(f"Queue: {QUEUE_NAME}")

    # Register signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Test database connection
    try:
        db = SessionLocal()
        db.execute("SELECT 1")
        db.close()
        logger.info("Database connection successful")
    except Exception as e:
        logger.error(f"Database connection failed: {e}")
        sys.exit(1)

    # Test Redis connection
    try:
        redis_conn = redis.from_url(REDIS_URL)
        redis_conn.ping()
        logger.info("Redis connection successful")
    except Exception as e:
        logger.error(f"Redis connection failed: {e}")
        sys.exit(1)

    # Create database tables if they don't exist (for development)
    # In production, use Alembic migrations instead
    if os.getenv("CREATE_TABLES", "false").lower() == "true":
        try:
            Base.metadata.create_all(bind=engine)
            logger.info("Database tables created/verified")
        except Exception as e:
            logger.warning(f"Could not create tables (this is OK if using Alembic): {e}")

    # Start RQ worker
    with Connection(redis.from_url(REDIS_URL)):
        queues = get_worker_queues()
        worker = Worker(
            queues,
            name="twinbox-worker",
            default_worker_ttl=600,  # 10 minutes default job timeout
            default_result_ttl=3600,  # 1 hour result retention
        )

        logger.info(f"Worker {worker.name} listening on queues: {[q.name for q in queues]}")
        logger.info("Worker ready to process jobs")

        try:
            worker.work()
        except KeyboardInterrupt:
            logger.info("Worker interrupted by keyboard")
        except Exception as e:
            logger.error(f"Worker crashed: {e}")
            raise
        finally:
            logger.info("Worker shutting down")


if __name__ == "__main__":
    main()
