#!/usr/bin/env bash
#
# Plan Executor - Executes VM creation plans with rollback capability
# Implements safe execution with progress tracking and logging

set -eo pipefail

# ============================================================================
# Execution Result Structures
# ============================================================================

StepResult=(
    title: string
    command: string
    ok: bool
    returncode: int
    output: string
)

ApplyResult=(
    ok: bool
    results: array
    log_path: string
)

# ============================================================================
# Progress Callback
# ============================================================================

# User-defined callback function (can be overridden)
on_step_start() {
    local current="$1"
    local total="$2"
    local title="$3"

    echo "[$current/$total] Starting: $title"
}

on_step_complete() {
    local current="$1"
    local total="$2"
    local title="$3"
    local ok="$4"

    if $ok; then
        echo "[$current/$total] ✓ $title"
    else
        echo "[$current/$total] ✗ $title"
    fi
}

# ============================================================================
# Plan Execution
# ============================================================================

execute_plan() {
    local plan_file="$1"
    local execute="${2:-false}"  # false = dry-run, true = actual execution

    log_info "Executing plan: $plan_file (execute=$execute)"

    if [[ ! -f "$plan_file" ]]; then
        log_error "Plan file not found: $plan_file"
        return 1
    fi

    if ! validate_plan "$plan_file"; then
        log_error "Plan validation failed: $plan_file"
        return 1
    fi

    # Create log directory
    local log_dir="$LOG_DIR/executions"
    mkdir -p "$log_dir"

    # Generate log filename
    local timestamp
    timestamp=$(date -Iseconds | tr ':' '-')
    local log_file="$log_dir/execute-${timestamp}.log"

    # Load plan
    local total_steps
    total_steps=$(jq '.steps | length' "$plan_file")
    local config_file
    config_file=$(jq -r '.metadata.config_file' "$plan_file")

    log_info "Plan has $total_steps steps, config: $config_file"
    echo "=== Execution Plan ===" | tee -a "$log_file"
    echo "Config: $config_file" | tee -a "$log_file"
    echo "Mode: $([[ "$execute" == "true" ]] && echo "EXECUTE" || echo "DRY-RUN")" | tee -a "$log_file"
    echo "Started: $(date)" | tee -a "$log_file"
    echo "" | tee -a "$log_file"

    # Create snapshot before execution (if executing)
    local snapshot_file=""
    if [[ "$execute" == "true" ]]; then
        local vmid
        vmid=$(jq -r '.metadata.vmid // empty' "$plan_file" 2>/dev/null || echo "")
        if [[ -n "$vmid" && "$vmid" != "null" ]]; then
            if vm_exists "$vmid"; then
                log_info "Creating pre-execution snapshot for VM $vmid"
                if snapshot_file=$(create_snapshot "$vmid" "pre-execute-${timestamp}"); then
                    log_info "Snapshot created: $snapshot_file"
                    echo "Pre-execution snapshot: $snapshot_file" | tee -a "$log_file"
                else
                    log_warn "Failed to create snapshot, continuing anyway"
                fi
            fi
        fi
    fi

    # Execute steps
    local results=()
    local current=1
    local overall_ok=true

    # Read steps from plan
    local step_titles
    step_titles=$(jq -r '.steps[].title' "$plan_file")
    local step_argv
    step_argv=$(jq -r '.steps[].argv[]' "$plan_file")

    # Process each step
    while IFS= read -r title; do
        echo "" | tee -a "$log_file"
        echo "Step $current/$total_steps: $title" | tee -a "$log_file"

        # Get command for this step
        local cmd
        cmd=$(jq -r --arg idx "$((current-1))" '.steps[$idx|tonumber].argv | join(" ")' "$plan_file")

        if on_step_start "$current" "$total_steps" "$title"; then
            echo "Command: $cmd" | tee -a "$log_file"
        fi

        local result_ok=false
        local result_rc=0
        local result_output=""

        if [[ "$execute" == "true" ]]; then
            # Actual execution
            if output=$(run_command $cmd 2>&1); then
                result_ok=true
                result_rc=0
                result_output="$output"
                echo "$output" | tee -a "$log_file"
            else
                result_ok=false
                result_rc=$?
                result_output="$output"
                echo "$output" | tee -a "$log_file"
                overall_ok=false
            fi
        else
            # Dry-run
            echo "[DRY-RUN] Would execute: $cmd" | tee -a "$log_file"
            result_ok=true
            result_rc=0
            result_output="[DRY-RUN] $cmd"
        fi

        # Record result
        results+=("$title:$result_ok:$result_rc")

        if on_step_complete "$current" "$total_steps" "$title" "$result_ok"; then
            if $result_ok; then
                echo "Status: SUCCESS" | tee -a "$log_file"
            else
                echo "Status: FAILED (exit code: $result_rc)" | tee -a "$log_file"
            fi
        fi

        # Stop on failure if executing
        if [[ "$execute" == "true" && ! $result_ok ]]; then
            log_error "Step failed: $title"
            echo "" | tee -a "$log_file"
            echo "Execution stopped due to failure" | tee -a "$log_file"
            break
        fi

        current=$((current + 1))
    done <<< "$step_titles"

    # Summary
    echo "" | tee -a "$log_file"
    echo "=== Execution Summary ===" | tee -a "$log_file"
    echo "Completed: $((current-1))/$total_steps steps" | tee -a "$log_file"

    local success_count=0
    local failure_count=0
    for result in "${results[@]}"; do
        IFS=':' read -r _title _ok _rc <<< "$result"
        if [[ "$_ok" == "true" ]]; then
            ((success_count++))
        else
            ((failure_count++))
        fi
    done

    echo "Successful: $success_count" | tee -a "$log_file"
    echo "Failed: $failure_count" | tee -a "$log_file"
    echo "Log: $log_file" | tee -a "$log_file"

    if $overall_ok; then
        log_info "Plan execution completed successfully"
    else
        log_error "Plan execution failed"
    fi

    # Rollback on failure if executing
    if [[ "$execute" == "true" && ! $overall_ok ]]; then
        if [[ -n "$snapshot_file" && -f "$snapshot_file" ]]; then
            log_warn "Rolling back due to execution failure"
            local vmid
            vmid=$(jq -r '.metadata.vmid // empty' "$plan_file" 2>/dev/null || echo "")
            if [[ -n "$vmid" && "$vmid" != "null" ]]; then
                if restore_snapshot "$vmid" "$snapshot_file"; then
                    log_info "Rollback completed"
                    echo "Rollback: completed" | tee -a "$log_file"
                else
                    log_error "Rollback failed"
                    echo "Rollback: FAILED" | tee -a "$log_file"
                fi
            fi
        fi
    fi

    if $overall_ok; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# VM Creation Wrapper
# ============================================================================

create_vm() {
    local profile="$1"

    log_info "Creating VM with profile: $profile"

    # Find profile file
    local profile_file=""
    if [[ -f "$profile" ]]; then
        profile_file="$profile"
    elif [[ -f "$CONFIG_DIR/profiles/$profile.yaml" ]]; then
        profile_file="$CONFIG_DIR/profiles/$profile.yaml"
    elif [[ -f "./$profile.yaml" ]]; then
        profile_file="./$profile.yaml"
    else
        log_error "Profile not found: $profile"
        return 1
    fi

    log_info "Using profile file: $profile_file"

    # Validate configuration
    if ! validate_config_yaml "$profile_file"; then
        log_error "Configuration validation failed"
        return 1
    fi

    # Generate plan
    local plan_file="$PLAN_DIR/plan-$(date +%Y%m%d-%H%M%S).json"
    if ! generate_vm_plan "$profile_file" "$plan_file"; then
        log_error "Failed to generate plan"
        return 1
    fi

    # Show plan
    echo ""
    render_plan "$plan_file"
    echo ""

    # Confirm execution
    if [[ "${FORCE:-0}" != "1" ]]; then
        read -r -p "Execute this plan? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Plan execution cancelled by user"
            echo "Cancelled."
            return 0
        fi
    fi

    # Execute plan
    if execute_plan "$plan_file" "true"; then
        log_info "VM created successfully"
        echo "✓ VM created successfully"

        # Show VM info
        local vmid
        vmid=$(yq eval '.vmid' "$profile_file")
        echo ""
        echo "VM Details:"
        echo "  VMID: $vmid"
        if get_vm_ip "$vmid" 60 &>/dev/null; then
            local ip
            ip=$(get_vm_ip "$vmid" 60)
            echo "  IP: $ip"
        fi
        return 0
    else
        log_error "VM creation failed"
        echo "✗ VM creation failed"
        return 1
    fi
}

# Export functions
export -f execute_plan create_vm
export -f on_step_start on_step_complete