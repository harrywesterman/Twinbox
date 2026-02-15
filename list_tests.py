#!/usr/bin/env python3
"""
List all tests in the test suite with descriptions.
"""

import os
import re

def extract_test_functions(filepath):
    """Extract test function names and docstrings from a Python file."""
    tests = []
    try:
        with open(filepath, 'r') as f:
            content = f.read()

        # Find test functions and classes
        # Match: def test_... or class Test...
        pattern = r'(?:def (test_\w+)\(|class (Test\w+))'
        matches = re.finditer(pattern, content)

        for match in matches:
            if match.group(1):  # function
                func_name = match.group(1)
                # Try to get docstring
                # Look for """ after the def line
                func_start = match.end()
                next_lines = content[func_start:func_start+500]
                doc_match = re.search(r'"""([^"]+)"""', next_lines)
                doc = doc_match.group(1).strip() if doc_match else ""
                tests.append((func_name, doc, filepath))
            elif match.group(2):  # class
                class_name = match.group(2)
                tests.append((class_name, f"Test class: {class_name}", filepath))

    except Exception as e:
        print(f"Error reading {filepath}: {e}")

    return tests

def main():
    base_dir = '/home/harry/Twinbox/tests'
    all_tests = []

    print("=" * 80)
    print("TWINBOX TEST SUITE - TEST INDEX")
    print("=" * 80)
    print()

    # Unit tests
    print("UNIT TESTS")
    print("-" * 80)

    unit_dir = os.path.join(base_dir, 'unit')
    for filename in sorted(os.listdir(unit_dir)):
        if filename.startswith('test_') and filename.endswith('.py'):
            filepath = os.path.join(unit_dir, filename)
            tests = extract_test_functions(filepath)
            if tests:
                print(f"\n📁 {filename}")
                for test_name, doc, _ in tests:
                    if doc:
                        print(f"  ✓ {test_name}")
                        print(f"    └─ {doc}")
                    else:
                        print(f"  ✓ {test_name}")

            all_tests.extend(tests)

    # Integration tests
    print("\n" + "=" * 80)
    print("INTEGRATION TESTS")
    print("-" * 80)

    int_dir = os.path.join(base_dir, 'integration')
    for filename in sorted(os.listdir(int_dir)):
        if filename.startswith('test_') and filename.endswith('.py'):
            filepath = os.path.join(int_dir, filename)
            tests = extract_test_functions(filepath)
            if tests:
                print(f"\n📁 {filename}")
                for test_name, doc, _ in tests:
                    if doc:
                        print(f"  ✓ {test_name}")
                        print(f"    └─ {doc}")
                    else:
                        print(f"  ✓ {test_name}")

            all_tests.extend(tests)

    # Summary
    print("\n" + "=" * 80)
    print("SUMMARY")
    print("-" * 80)
    print(f"Total test files: {len(set(t[2] for t in all_tests))}")
    print(f"Total test functions/classes: {len(all_tests)}")
    print()

    # Count by type
    unit_count = sum(1 for t in all_tests if 'unit' in t[2])
    int_count = sum(1 for t in all_tests if 'integration' in t[2])
    print(f"  Unit tests: ~{unit_count}")
    print(f"  Integration tests: ~{int_count}")

    print("\n" + "=" * 80)
    print("To run all tests: make test")
    print("To run unit tests: make unit")
    print("To run with coverage: make coverage")
    print("=" * 80)

if __name__ == '__main__':
    main()
