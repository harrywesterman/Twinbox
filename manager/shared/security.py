"""
Security module for credential encryption and decryption.
Uses Fernet symmetric encryption with keys derived from SECRET_KEY.
"""

import os
import hashlib
from cryptography.fernet import Fernet
from typing import Optional


def get_encryption_key() -> bytes:
    """
    Derive a 32-byte encryption key from SECRET_KEY environment variable.
    Uses SHA256 to ensure consistent key length regardless of input.

    Returns:
        32-byte key suitable for Fernet encryption

    Raises:
        ValueError: If SECRET_KEY is not set
    """
    secret_key = os.environ.get("SECRET_KEY")
    if not secret_key:
        raise ValueError("SECRET_KEY environment variable must be set")

    # Derive 32-byte key using SHA256
    key = hashlib.sha256(secret_key.encode()).digest()
    return Fernet(base64.urlsafe_b64encode(key))


def encrypt_credentials(data: str, key: Optional[bytes] = None) -> str:
    """
    Encrypt sensitive credential data using Fernet encryption.

    Args:
        data: Plaintext credential string to encrypt
        key: Optional encryption key (uses get_encryption_key() if not provided)

    Returns:
        Encrypted credential string (URL-safe base64)
    """
    if key is None:
        fernet = get_encryption_key()
    else:
        fernet = Fernet(key)

    return fernet.encrypt(data.encode()).decode()


def decrypt_credentials(encrypted: str, key: Optional[bytes] = None) -> str:
    """
    Decrypt encrypted credential data.

    Args:
        encrypted: Encrypted credential string
        key: Optional encryption key (uses get_encryption_key() if not provided)

    Returns:
        Decrypted plaintext credential string

    Raises:
        cryptography.fernet.InvalidToken: If encryption key is wrong or data corrupted
    """
    if key is None:
        fernet = get_encryption_key()
    else:
        fernet = Fernet(key)

    return fernet.decrypt(encrypted.encode()).decode()
