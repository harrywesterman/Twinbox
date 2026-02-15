"""
Database connection and session management.
"""

from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
from typing import Generator, Optional
import os

Base = declarative_base()


class Database:
    """
    Database connection manager.
    """

    def __init__(self, url: str = None):
        """
        Initialize database connection.

        Args:
            url: Database URL (e.g., postgresql://user:pass@host/db, sqlite:///file.db)
        """
        if url is None:
            # Default to SQLite for development
            url = os.getenv("DATABASE_URL", "sqlite:///./twinbox.db")

        self.url = url
        self.engine = create_engine(url, echo=False)
        self.SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=self.engine)

    def create_tables(self) -> None:
        """Create all tables."""
        Base.metadata.create_all(bind=self.engine)

    def drop_tables(self) -> None:
        """Drop all tables."""
        Base.metadata.drop_all(bind=self.engine)

    def get_session(self) -> Generator[Session, None, None]:
        """
        Get a database session.

        Yields:
            Session instance
        """
        session = self.SessionLocal()
        try:
            yield session
            session.commit()
        except Exception:
            session.rollback()
            raise
        finally:
            session.close()

    def get_session_sync(self) -> Session:
        """Get a synchronous session (for non-generator use)."""
        return self.SessionLocal()


# Global database instance
db = Database()


def init_db() -> None:
    """Initialize database with default connection."""
    global db
    db.create_tables()


def get_db() -> Generator[Session, None, None]:
    """
    FastAPI dependency to get database session.
    """
    session = db.SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
