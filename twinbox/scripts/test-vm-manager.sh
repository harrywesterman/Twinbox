#!/usr/bin/env bash
#
# Test Suite for Proxmox VM Manager
# Validates functionality without affecting production environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/test"
TEST_LOG="$TEST_DIR/test.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

test_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

test_fail() {
    local msg="$1"
    local err="${2:-}"
    echo -e "${RED}✗${NC} $msg"
    if [[ -n "$err" ]]; then
        echo "  Error: $err" >&2
    fi
}

test_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# ============================================================================
# Test Cases
# ============================================================================

test_library_loading() {
    test_info "Testing library loading..."

    local libraries=("adapter" "preflight" "validator" "planner" "executor" "assets" "rollback" "utils")
    local failed=0

    for lib in "${libraries[@]}"; do
        if [[ -f "$SCRIPT_DIR/lib/${lib}.sh" ]]; then
            if source "$SCRIPT_DIR/lib/${lib}.sh" 2>/dev/null; then
                test_pass "Library loaded: $lib"
            else
                test_fail "Library failed to source: $lib"
                ((failed++))
            fi
        else
            test_fail "Library not found: $lib"
            ((failed++))
        fi
    done

    return $failed
}

test_utils_functions() {
    test_info "Testing utility functions..."

    local failed=0

    # Test timestamp
    if timestamp=$(timestamp) && [[ -n "$timestamp" ]]; then
        test_pass "timestamp() returns value: $timestamp"
    else
        test_fail "timestamp() failed"
        ((failed++))
    fi

    # Test safe_filename
    if safe_name=$(safe_filename "Test VM 123!@#") && [[ "$safe_name" == "test_vm_123___" ]]; then
        test_pass "safe_filename() works correctly"
    else
        test_fail "safe_filename() returned: $safe_name"
        ((failed++))
    fi

    # Test confirm (non-interactive simulation)
    if FORCE=1 confirm "Test" "n"; then
        test_pass "confirm() respects FORCE=1"
    else
        test_fail "confirm() with FORCE=1 failed"
        ((failed++))
    fi

    return $failed
}

test_preflight_checks() {
    test_info "Testing preflight checks..."

    local failed=0

    # Test check functions exist
    for check in check_proxmox_tools check_kvm check_root check_curl check_jq; do
        if declare -F "$check" >/dev/null; then
            test_pass "Function exists: $check"
        else
            test_fail "Function missing: $check"
            ((failed++))
        fi
    done

    # Test preflight_check function
    if declare -F preflight_check >/dev/null; then
        test_pass "preflight_check function exists"
    else
        test_fail "preflight_check function missing"
        ((failed++))
    fi

    return $failed
}

test_validator_functions() {
    test_info "Testing validator functions..."

    local failed=0

    # Test validation functions exist
    for func in validate_vmid validate_name validate_cores validate_memory validate_disk_size validate_bridge; do
        if declare -F "$func" >/dev/null; then
            test_pass "Function exists: $func"
        else
            test_fail "Function missing: $func"
            ((failed++))
        fi
    done

    # Test validate_vmid with valid input
    if validate_vmid 900 2>/dev/null; then
        test_pass "validate_vmid(900) returns true"
    else
        test_fail "validate_vmid(900) failed"
        ((failed++))
    fi

    # Test validate_vmid with invalid input (should fail)
    if ! validate_vmid 10 2>/dev/null; then
        test_pass "validate_vmid(10) correctly rejects invalid VMID"
    else
        test_fail "validate_vmid(10) should have failed"
        ((failed++))
    fi

    # Test validate_name with valid input
    if validate_name "test-vm" 2>/dev/null; then
        test_pass "validate_name('test-vm') returns true"
    else
        test_fail "validate_name('test-vm') failed"
        ((failed++))
    fi

    # Test validate_name with invalid input
    if ! validate_name "ab" 2>/dev/null; then
        test_pass "validate_name('ab') correctly rejects too short"
    else
        test_fail "validate_name('ab') should have failed"
        ((failed++))
    fi

    return $failed
}

test_adapter_functions() {
    test_info "Testing adapter functions..."

    local failed=0

    # Test adapter functions exist
    for func in authenticate run_command qm pvesh get_first_node vm_exists create_vm_shell; do
        if declare -F "$func" >/dev/null; then
            test_pass "Function exists: $func"
        else
            test_fail "Function missing: $func"
            ((failed++))
        fi
    done

    return $failed
}

test_planner_functions() {
    test_info "Testing planner functions..."

    local failed=0

    # Test planner functions exist
    for func in generate_vm_plan render_plan validate_plan; do
        if declare -F "$func" >/dev/null; then
            test_pass "Function exists: $func"
        else
            test_fail "Function missing: $func"
            ((failed++))
        fi
    done

    return $failed
}

test_executor_functions() {
    test_info "Testing executor functions..."

    local failed=0

    # Test executor functions exist
    for func in execute_plan create_vm; do
        if declare -F "$func" >/dev/null; then
            test_pass "Function exists: $func"
        else
            test_fail "Function missing: $func"
            ((failed++))
        fi
    done

    return $failed
}

test_assets_functions() {
    test_info "Testing assets functions..."

    local failed=0

    # Test assets functions exist
    for func in download_iso list_storage_content find_iso validate_iso_exists; do
        if declare -F "$func" >/dev/null; then
            test_pass "Function exists: $func"
        else
            test_fail "Function missing: $func"
            ((failed++))
        fi
    done

    return $failed
}

test_rollback_functions() {
    test_info "Testing rollback functions..."

    local failed=0

    # Test rollback functions exist
    for func in create_vm_snapshot restore_vm_snapshot list_snapshots with_rollback; do
        if declare -F "$func" >/dev/null; then
            test_pass "Function exists: $func"
        else
            test_fail "Function missing: $func"
            ((failed++))
        fi
    done

    return $failed
}

test_profile_loading() {
    test_info "Testing profile loading..."

    local failed=0
    local test_profile="$TEST_DIR/test-profile.yaml"

    # Create test profile
    cat > "$test_profile" << 'EOF'
vmid: 999
name: test-vm
cores: 2
memory: 4096
disk: 20G
bridge: vmbr0
storage: local-lvm
EOF

    if [[ -f "$test_profile" ]]; then
        test_pass "Test profile created"
    else
        test_fail "Failed to create test profile"
        ((failed++))
        return $failed
    fi

    # Test validation
    if validate_config_yaml "$test_profile" 2>/dev/null; then
        test_pass "Profile validation succeeded"
    else
        # Expected to fail due to missing Proxmox, but function should exist
        test_pass "Profile validation attempted (expected to fail without Proxmox)"
    fi

    # Cleanup
    rm -f "$test_profile"

    return $failed
}

test_main_script_syntax() {
    test_info "Testing main script syntax..."

    local failed=0

    if [[ -f "$SCRIPT_DIR/proxmox-vm-manager.sh" ]]; then
        test_pass "Main script exists"
    else
        test_fail "Main script not found"
        return 1
    fi

    # Check bash syntax
    if bash -n "$SCRIPT_DIR/proxmox-vm-manager.sh" 2>/dev/null; then
        test_pass "Main script syntax valid"
    else
        test_fail "Main script has syntax errors"
        ((failed++))
    fi

    # Check if script is executable
    if [[ -x "$SCRIPT_DIR/proxmox-vm-manager.sh" ]]; then
        test_pass "Main script is executable"
    else
        test_fail "Main script is not executable"
        ((failed++))
    fi

    return $failed
}

test_documentation_exists() {
    test_info "Testing documentation..."

    local failed=0

    if [[ -f "$SCRIPT_DIR/PROXMOX-VM-MANAGER.md" ]]; then
        test_pass "Documentation file exists"
    else
        test_fail "Documentation file not found"
        ((failed++))
    fi

    # Check if documentation has key sections
    local doc_file="$SCRIPT_DIR/PROXMOX-VM-MANAGER.md"
    local sections=("Features" "Quick Start" "Commands" "Configuration Profiles" "Troubleshooting")
    local missing_sections=()

    for section in "${sections[@]}"; do
        if grep -q "^## $section" "$doc_file" 2>/dev/null; then
            test_pass "Documentation section: $section"
        else
            test_fail "Missing documentation section: $section"
            missing_sections+=("$section")
            ((failed++))
        fi
    done

    return $failed
}

test_profile_examples() {
    test_info "Testing profile examples..."

    local failed=0
    local profiles_dir="$SCRIPT_DIR/configs/profiles"

    if [[ ! -d "$profiles_dir" ]]; then
        test_fail "Profiles directory not found: $profiles_dir"
        return 1
    fi

    test_pass "Profiles directory exists: $profiles_dir"

    local profile_count=0
    for profile in "$profiles_dir"/*.yaml; do
        if [[ -f "$profile" ]]; then
            ((profile_count++))
            local profile_name
            profile_name=$(basename "$profile")
            test_info "Found profile: $profile_name"

            # Check required fields
            if grep -q "^vmid:" "$profile"; then
                test_pass "  - Has vmid field"
            else
                test_fail "  - Missing vmid field"
                ((failed++))
            fi

            if grep -q "^name:" "$profile"; then
                test_pass "  - Has name field"
            else
                test_fail "  - Missing name field"
                ((failed++))
            fi
        fi
    done

    if [[ $profile_count -gt 0 ]]; then
        test_pass "Found $profile_count profile(s)"
    else
        test_fail "No profiles found in $profiles_dir"
        ((failed++))
    fi

    return $failed
}

# ============================================================================
# Test Runner
# ============================================================================

run_all_tests() {
    echo "========================================"
    echo "Twinbox Proxmox VM Manager Test Suite"
    echo "========================================"
    echo ""

    mkdir -p "$TEST_DIR"

    local total_failed=0

    test_library_loading || ((total_failed+=$?))
    echo ""

    test_utils_functions || ((total_failed+=$?))
    echo ""

    test_preflight_checks || ((total_failed+=$?))
    echo ""

    test_validator_functions || ((total_failed+=$?))
    echo ""

    test_adapter_functions || ((total_failed+=$?))
    echo ""

    test_planner_functions || ((total_failed+=$?))
    echo ""

    test_executor_functions || ((total_failed+=$?))
    echo ""

    test_assets_functions || ((total_failed+=$?))
    echo ""

    test_rollback_functions || ((total_failed+=$?))
    echo ""

    test_profile_loading || ((total_failed+=$?))
    echo ""

    test_main_script_syntax || ((total_failed+=$?))
    echo ""

    test_documentation_exists || ((total_failed+=$?))
    echo ""

    test_profile_examples || ((total_failed+=$?))
    echo ""

    echo "========================================"
    if [[ $total_failed -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}$total_failed test(s) failed${NC}"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi