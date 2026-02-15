#!/usr/bin/env python3
"""
Simple test runner script for Twinbox.
Installs dependencies if needed and runs tests.
"""

import subprocess
import sys
import os

def main():
    """Run the test suite."""

    # Change to twinbox directory
    os.chdir('/home/harry/Twinbox')

    print("=" * 70)
    print("Twinbox Test Suite")
    print("=" * 70)

    # Check if dependencies are installed
    try:
        import pytest
        import httpx
        print("\n✓ Dependencies are installed")
    except ImportError as e:
        print(f"\n✗ Missing dependency: {e}")
        print("\nInstalling test dependencies...")
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "-r", "requirements-test.txt"],
            capture_output=False
        )
        if result.returncode != 0:
            print("✗ Failed to install dependencies")
            return 1
        print("✓ Dependencies installed")

    # Run tests based on arguments
    import pytest
    args = sys.argv[1:] if len(sys.argv) > 1 else ['-v']

    print(f"\nRunning tests with arguments: {' '.join(args)}")
    print("-" * 70)

    exit_code = pytest.main(args)

    if exit_code == 0:
        print("\n" + "=" * 70)
        print("✓ All tests passed!")
        print("=" * 70)
    else:
        print("\n" + "=" * 70)
        print(f"✗ Tests failed with exit code {exit_code}")
        print("=" * 70)

    return exit_code

if __name__ == '__main__':
    sys.exit(main())
