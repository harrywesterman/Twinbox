"""
API router for cluster management.

Endpoints:
- POST /api/cluster - Create a new cluster
- GET /api/cluster/{id} - Get cluster details
- POST /api/cluster/{id}/deploy - Start deployment
"""

import logging
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status, Request
from sqlalchemy.orm import Session

from manager.shared.database import Cluster
from .schemas import ClusterCreate, ClusterResponse, DeployRequest, ReviewPlan
from ..services.cluster_service import ClusterService, get_cluster_service

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["clusters"])


@router.post(
    "/cluster",
    response_model=ClusterResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new cluster",
    description="Create a new cluster with Proxmox and network configuration"
)
def create_cluster(
    request: Request,
    cluster_data: ClusterCreate,
    cluster_service: ClusterService = Depends(get_cluster_service)
) -> ClusterResponse:
    """
    Create a new cluster.

    This creates a cluster record with encrypted Proxmox credentials.
    The cluster is in 'pending' state until review and deployment.

    Args:
        request: FastAPI request object
        cluster_data: Cluster configuration
        cluster_service: ClusterService dependency

    Returns:
        Created cluster with UUID and metadata

    Raises:
        HTTPException 400: If validation fails or cluster name exists
        HTTPException 500: If creation fails
    """
    try:
        cluster = cluster_service.create_cluster(cluster_data)
        return ClusterResponse.model_validate(cluster)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )
    except Exception as e:
        logger.exception(f"Failed to create cluster: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to create cluster"
        )


@router.get(
    "/cluster/{cluster_id}",
    response_model=ClusterResponse,
    summary="Get cluster details",
    description="Retrieve cluster information by ID"
)
def get_cluster(
    cluster_id: UUID,
    cluster_service: ClusterService = Depends(get_cluster_service)
) -> ClusterResponse:
    """
    Get cluster by UUID.

    Args:
        cluster_id: Cluster UUID
        cluster_service: ClusterService dependency

    Returns:
        Cluster details

    Raises:
        HTTPException 404: If cluster not found
    """
    cluster = cluster_service.get_cluster(cluster_id)
    if not cluster:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Cluster {cluster_id} not found"
        )
    return ClusterResponse.model_validate(cluster)


@router.get(
    "/clusters",
    response_model=list[ClusterResponse],
    summary="List all clusters",
    description="List all clusters with basic information"
)
def list_clusters(
    cluster_service: ClusterService = Depends(get_cluster_service)
) -> list[ClusterResponse]:
    """
    List all clusters.

    Returns:
        List of all clusters ordered by creation date (newest first)
    """
    clusters = cluster_service.list_clusters()
    return [ClusterResponse.model_validate(c) for c in clusters]


@router.post(
    "/cluster/{cluster_id}/deploy",
    response_model=dict,
    summary="Start cluster deployment",
    description="Generate review plan and start deployment"
)
def start_deployment(
    request: Request,
    cluster_id: UUID,
    deploy_request: DeployRequest,
    cluster_service: ClusterService = Depends(get_cluster_service)
) -> dict:
    """
    Start deployment for a cluster.

    This enqueues a series of background jobs to provision the cluster.

    Args:
        request: FastAPI request object
        cluster_id: Cluster UUID
        deploy_request: Deployment confirmation request
        cluster_service: ClusterService dependency

    Returns:
        Dictionary with deployment_id and status

    Raises:
        HTTPException 400: If deployment not confirmed or cluster invalid
        HTTPException 404: If cluster not found
        HTTPException 409: If cluster is already deploying
        HTTPException 500: If deployment start fails
    """
    if not deploy_request.confirm:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Deployment must be confirmed with confirm=true"
        )

    try:
        cluster = cluster_service.get_cluster(cluster_id)
        if not cluster:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Cluster {cluster_id} not found"
            )

        deployment_id = cluster_service.start_deployment(cluster_id)
        logger.info(f"Started deployment {deployment_id} for cluster {cluster_id}")

        return {
            "deployment_id": deployment_id,
            "status": "started",
            "message": "Deployment started successfully"
        }
    except ValueError as e:
        logger.error(f"Failed to start deployment: {e}")
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )
    except Exception as e:
        logger.exception(f"Failed to start deployment: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to start deployment"
        )


@router.get(
    "/cluster/{cluster_id}/review",
    response_model=ReviewPlan,
    summary="Generate deployment review plan",
    description="Generate complete deployment plan for review before starting"
)
def generate_review_plan(
    cluster_id: UUID,
    cluster_service: ClusterService = Depends(get_cluster_service)
) -> ReviewPlan:
    """
    Generate review plan for cluster deployment.

    This discovers the Proxmox topology, calculates VM placement,
    and returns a complete deployment plan for user review.

    Args:
        cluster_id: Cluster UUID
        cluster_service: ClusterService dependency

    Returns:
        ReviewPlan with VMs, network config, and resource summary

    Raises:
        HTTPException 404: If cluster not found
        HTTPException 500: If plan generation fails
    """
    try:
        review_plan = cluster_service.generate_review_plan(cluster_id)
        return review_plan
    except ValueError as e:
        logger.error(f"Failed to generate review plan: {e}")
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )
    except Exception as e:
        logger.exception(f"Failed to generate review plan: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to generate deployment plan"
        )
