"""
Database configuration and session management for Twinbox.

Provides SQLAlchemy engine setup, session factory, and Base declarative class.
Uses PostgreSQL dialect with connection pooling and proper configuration.
"""

import os
from typing import Any, Generator
from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import sessionmaker, declarative_base, Session
from sqlalchemy.pool import QueuePool

# Environment variable for database URL
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg2://postgres:postgres@localhost:5432/twinbox"
)

# Create SQLAlchemy engine with connection pooling
engine: Engine = create_engine(
    DATABASE_URL,
    poolclass=QueuePool,
    pool_size=5,
    max_overflow=10,
    pool_pre_ping=True,
    pool_recycle=3600,
    echo=False,  # Set to True for debugging
    future=True,
)

# Session factory
SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
    expire_on_commit=False,
)

# Base declarative class for ORM models
Base = declarative_base()


@event.listens_for(Engine, "connect")
def set_postgresql_pg_version(dbapi_connection: Any, connection_record: Any) -> None:
    """Set PostgreSQL session parameters on connection."""
    cursor = dbapi_connection.cursor()
    cursor.execute("SET timezone='UTC'")
    cursor.execute("SET search_path TO public")
    cursor.close()


def init_db() -> None:
    """
    Initialize database by creating all tables.

    Should be called on application startup. For production migrations,
    use Alembic instead of this method.
    """
    Base.metadata.create_all(bind=engine)


def get_db() -> Generator[Session, None, None]:
    """
    Dependency for FastAPI/other frameworks to get database session.

    Yields:
        Database session that will be automatically closed.

    Example:
        >>> db = next(get_db())
        >>> # use db
        >>> db.close()
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
