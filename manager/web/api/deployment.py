"""
API router for deployment monitoring.

Endpoints:
- GET /api/deployment/{id}/status - Get deployment status
- GET /api/deployment/{id}/logs - Get deployment logs
- GET /api/deployment/{id}/logs/stream - Stream logs via SSE
"""

import asyncio
import logging
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status, Query, Request
from sqlalchemy.orm import Session

from .schemas import DeploymentStatus, LogEntry
from ..services.deployment_service import DeploymentService, get_deployment_service

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["deployments"])


@router.get(
    "/deployment/{deployment_id}/status",
    response_model=DeploymentStatus,
    summary="Get deployment status",
    description="Get current status and progress of a deployment"
)
def get_deployment_status(
    deployment_id: UUID,
    deployment_service: DeploymentService = Depends(get_deployment_service)
) -> DeploymentStatus:
    """
    Get deployment status.

    Args:
        deployment_id: Deployment UUID
        deployment_service: DeploymentService dependency

    Returns:
        DeploymentStatus with progress, current step, and timestamps

    Raises:
        HTTPException 404: If deployment not found
    """
    status_data = deployment_service.get_deployment_status(deployment_id)
    if status_data is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Deployment {deployment_id} not found"
        )
    return status_data


@router.get(
    "/deployment/{deployment_id}/logs",
    response_model=list[LogEntry],
    summary="Get deployment logs",
    description="Get recent deployment logs with pagination"
)
def get_deployment_logs(
    deployment_id: UUID,
    limit: int = Query(100, ge=1, le=1000, description="Number of log entries to return"),
    offset: int = Query(0, ge=0, description="Number of recent entries to skip"),
    deployment_service: DeploymentService = Depends(get_deployment_service)
) -> list[LogEntry]:
    """
    Get deployment logs as a static list.

    Logs are ordered by timestamp descending (newest first).

    Args:
        deployment_id: Deployment UUID
        limit: Maximum entries to return (default 100, max 1000)
        offset: Skip this many recent entries
        deployment_service: DeploymentService dependency

    Returns:
        List of LogEntry objects

    Raises:
        HTTPException 404: If deployment not found
    """
    # Verify deployment exists
    deployment = deployment_service.get_deployment(deployment_id)
    if not deployment:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Deployment {deployment_id} not found"
        )

    logs = deployment_service.get_logs(deployment_id, limit=limit, offset=offset)
    return logs


@router.get(
    "/deployment/{deployment_id}/logs/stream",
    summary="Stream deployment logs",
    description="Stream deployment logs in real-time using Server-Sent Events (SSE)"
)
async def stream_deployment_logs(
    request: Request,
    deployment_id: UUID,
    deployment_service: DeploymentService = Depends(get_deployment_service)
):
    """
    Stream deployment logs via Server-Sent Events.

    This endpoint streams logs in real-time as they are written to the database.
    The connection remains open and logs are pushed as they arrive.

    Args:
        request: FastAPI request object (for SSE response)
        deployment_id: Deployment UUID
        deployment_service: DeploymentService dependency

    Returns:
        StreamingResponse with text/event-stream content type

    Raises:
        HTTPException 404: If deployment not found
    """
    from fastapi.responses import StreamingResponse

    # Verify deployment exists
    deployment = deployment_service.get_deployment(deployment_id)
    if not deployment:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Deployment {deployment_id} not found"
        )

    async def event_generator():
        """
        Generate SSE events from deployment logs.

        Each event has the format:
        data: {"id": "...", "level": "...", "message": "...", "timestamp": "..."}\n\n
        """
        try:
            # Use the synchronous stream_logs generator in an async wrapper
            for log_batch in deployment_service.stream_logs(deployment_id):
                # Convert batch to SSE format
                for log_entry in log_batch:
                    # Format as JSON
                    import json
                    data = json.dumps(log_entry)
                    # SSE format: "data: <json>\n\n"
                    yield f"data: {data}\n\n"

                # Check if client disconnected
                if await request.is_disconnected():
                    logger.info(f"Client disconnected from log stream for deployment {deployment_id}")
                    break

                # Small async sleep to yield control
                await asyncio.sleep(0)
        except Exception as e:
            logger.error(f"Error in log stream for deployment {deployment_id}: {e}")
            # Send error event
            yield f"event: error\ndata: {json.dumps({'error': str(e)})}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",  # Disable nginx buffering
        }
    )


@router.post(
    "/deployment/{deployment_id}/cancel",
    response_model=dict,
    summary="Cancel deployment",
    description="Cancel a running deployment"
)
def cancel_deployment(
    deployment_id: UUID,
    deployment_service: DeploymentService = Depends(get_deployment_service)
) -> dict:
    """
    Cancel a deployment.

    Marks the deployment as 'cancelled'. Background jobs will exit gracefully
    on their next check.

    Args:
        deployment_id: Deployment UUID
        deployment_service: DeploymentService dependency

    Returns:
        Success message

    Raises:
        HTTPException 404: If deployment not found
        HTTPException 400: If deployment already completed
    """
    success = deployment_service.cancel_deployment(deployment_id)
    if not success:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Deployment cannot be cancelled (not found or already completed)"
        )

    return {
        "deployment_id": str(deployment_id),
        "status": "cancelled",
        "message": "Deployment cancellation requested"
    }
