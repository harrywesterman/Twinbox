"""
Twinbox Web Application - FastAPI entry point.

Provides REST API for cluster management and deployment monitoring,
serves web UI templates and static files.
"""

import logging
import os
import sys
from pathlib import Path
from typing import Callable

from fastapi import FastAPI, Request, HTTPException, Depends
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from sqlalchemy.orm import Session

from manager.shared.database import engine, Base, get_db
from .api import cluster as cluster_router
from .api import deployment as deployment_router
from .api import kubeconfig as kubeconfig_router
# Don't import services at module level; use direct imports in route handlers

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

# Initialize FastAPI app
app = FastAPI(
    title="Twinbox",
    description="Kubernetes cluster deployment and management system",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS middleware (optional, enable if needed)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # TODO: Configure for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static files
static_dir = Path(__file__).parent / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
else:
    logger.warning(f"Static directory not found: {static_dir}")

# Setup templates
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


# ========== Startup and Shutdown Events ==========

@app.on_event("startup")
async def startup_event():
    """
    Startup event handler.

    Performs:
    - Database connection check
    - Run Alembic migrations (upgrade head)
    - Initialize Redis connection check
    """
    logger.info("Starting Twinbox application...")

    # Check database connection
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        logger.info("Database connection successful")
    except Exception as e:
        logger.error(f"Database connection failed: {e}")
        # Continue startup; will fail on first DB operation

    # Run Alembic migrations
    try:
        from alembic.config import Config
        from alembic import command

        alembic_cfg = Config(str(Path(__file__).parent.parent / "alembic.ini"))
        # Override sqlalchemy.url with actual DB URL from environment
        db_url = os.getenv("DATABASE_URL", engine.url.render_as_string(hide_password=True))
        alembic_cfg.set_main_option("sqlalchemy.url", db_url)

        logger.info("Running Alembic migrations...")
        command.upgrade(alembic_cfg, "head")
        logger.info("Alembic migrations completed")
    except Exception as e:
        logger.error(f"Alembic migration failed: {e}")
        # Don't fail startup; tables will be created on first access if needed

    # Check Redis connection
    try:
        import redis
        redis_url = os.getenv("REDIS_URL", os.getenv("REDIS_HOST", "localhost"))
        redis_conn = redis.from_url(f"redis://{redis_url}:6379/0")
        redis_conn.ping()
        logger.info("Redis connection successful")
        redis_conn.close()
    except Exception as e:
        logger.warning(f"Redis connection failed: {e}. Background jobs will not work.")

    logger.info("Twinbox application started")


@app.on_event("shutdown")
async def shutdown_event():
    """Shutdown event handler."""
    logger.info("Shutting down Twinbox application...")


# ========== Exception Handlers ==========

@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """Handle HTTP exceptions."""
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.detail, "status_code": exc.status_code}
    )


@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    """Handle unhandled exceptions."""
    logger.exception(f"Unhandled exception: {exc}")
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error", "details": str(exc)}
    )


# ========== Root Routes ==========

@app.get("/", response_class=HTMLResponse, summary="Web UI", tags=["UI"])
async def root(request: Request, db: Session = Depends(get_db)):
    """
    Render the main web UI.

    Shows cluster dashboard with list of clusters and deployment status.
    """
    from manager.web.services.cluster_service import ClusterService
    # Get list of clusters
    cluster_svc = ClusterService(db)
    clusters = cluster_svc.list_clusters()

    return templates.TemplateResponse(
        "index.html",
        {"request": request, "clusters": clusters}
    )


@app.get("/cluster/{cluster_id}/review", response_class=HTMLResponse, summary="Review Page", tags=["UI"])
async def review_page(
    request: Request,
    cluster_id: str,
    db: Session = Depends(get_db)
):
    """
    Render the review page for cluster deployment.

    Shows VM plan, resource allocation, and network configuration.
    """
    # TODO: Fetch review plan from service
    return templates.TemplateResponse(
        "review.html",
        {"request": request, "cluster_id": cluster_id}
    )


@app.get("/cluster/{cluster_id}/deploy", response_class=HTMLResponse, summary="Deploy Page", tags=["UI"])
async def deploy_page(
    request: Request,
    cluster_id: str,
    db: Session = Depends(get_db)
):
    """
    Render the deployment monitoring page.

    Shows real-time deployment logs and progress.
    """
    # TODO: Get deployment status
    return templates.TemplateResponse(
        "deploy.html",
        {"request": request, "cluster_id": cluster_id}
    )


@app.get("/cluster/{cluster_id}/complete", response_class=HTMLResponse, summary="Complete Page", tags=["UI"])
async def complete_page(
    request: Request,
    cluster_id: str,
    db: Session = Depends(get_db)
):
    """
    Render the deployment completion page.

    Shows success message and provides kubeconfig download.
    """
    # TODO: Get cluster details
    return templates.TemplateResponse(
        "complete.html",
        {"request": request, "cluster_id": cluster_id}
    )


# ========== Health Check ==========

@app.get("/health", summary="Health Check", tags=["Health"])
async def health_check():
    """
    Health check endpoint.

    Returns:
        JSON with status and component health
    """
    health = {"status": "healthy", "components": {}}

    # Check database
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        health["components"]["database"] = "healthy"
    except Exception as e:
        health["components"]["database"] = f"unhealthy: {e}"
        health["status"] = "degraded"

    # Check Redis
    try:
        import redis
        redis_url = os.getenv("REDIS_URL", os.getenv("REDIS_HOST", "localhost"))
        redis_conn = redis.from_url(f"redis://{redis_url}:6379/0")
        redis_conn.ping()
        redis_conn.close()
        health["components"]["redis"] = "healthy"
    except Exception as e:
        health["components"]["redis"] = f"unhealthy: {e}"
        health["status"] = "degraded"

    return health


# ========== Include API Routers ==========

app.include_router(cluster_router.router)
app.include_router(deployment_router.router)
app.include_router(kubeconfig_router.router)


# ========== Main Entry Point ==========

if __name__ == "__main__":
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    reload = os.getenv("RELOAD", "false").lower() == "true"

    logger.info(f"Starting uvicorn server on {host}:{port} (reload={reload})")
    uvicorn.run(
        "main:app",
        host=host,
        port=port,
        reload=reload,
        log_level="info"
    )
