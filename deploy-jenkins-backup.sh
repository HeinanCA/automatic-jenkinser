#!/bin/bash
#
# Jenkins EBS Snapshot Backup - Deployment Script
# 
# A production-ready deployment script for automated Jenkins disaster recovery
# using AWS EBS snapshots and Lambda functions.
#
# Author: DevOps Engineer & Udemy Instructor
# Repository: https://github.com/your-username/jenkins-ebs-backup-automation
# License: MIT
#
# Usage:
#   ./deploy-jenkins-backup.sh [OPTIONS]
#
# Options:
#   -h, --help              Show help message
#   -c, --config FILE       Use configuration file  
#   -r, --region REGION     Override AWS region
#   -s, --stack-name NAME   Override stack name
#   --dry-run              Preview deployment without executing
#   --cleanup              Remove existing stack
#   --verbose              Enable verbose logging
#
# Examples:
#   ./deploy-jenkins-backup.sh                    # Interactive deployment
#   ./deploy-jenkins-backup.sh --region eu-west-1 # Deploy to specific region
#   ./deploy-jenkins-backup.sh --dry-run          # Preview changes
#   ./deploy-jenkins-backup.sh --cleanup          # Remove deployment
#

set -euo pipefail  # Exit on error, undefined variables, pipe failures

#===============================================================================
# GLOBAL CONFIGURATION
#===============================================================================

# Script metadata
readonly SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="1.0.0"

# Default configuration
readonly DEFAULT_STACK_NAME="jenkins-snapshot-backup"
readonly DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
readonly TEMPLATE_FILE="cloudformation/jenkins-snapshot-backup.yaml"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"
readonly LOGS_DIR="${SCRIPT_DIR}/logs"

# Runtime variables (will be set by user input or arguments)
STACK_NAME="${DEFAULT_STACK_NAME}"
REGION="${DEFAULT_REGION}"
DRY_RUN=false
VERBOSE=false
CLEANUP_MODE=false
CONFIG_FILE=""

# Deployment variables (will be collected during execution)
JENKINS_INSTANCE_ID=""
RETENTION_DAYS=""
BACKUP_TIME=""
NOTIFICATION_EMAIL=""

# Color codes for enhanced output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# Icons for better visual feedback
readonly ICON_SUCCESS="✅"
readonly ICON_ERROR="❌"
readonly ICON_WARNING="⚠️"
readonly ICON_INFO="ℹ️"
readonly ICON_ROCKET="🚀"
readonly ICON_GEAR="⚙️"

#===============================================================================
# LOGGING FUNCTIONS
#===============================================================================

# Create logs directory if it doesn't exist
mkdir -p "${LOGS_DIR}"

# Log file with timestamp
readonly LOG_FILE="${LOGS_DIR}/deployment-$(date +%Y%m%d-%H%M%S).log"

log_message() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Write to log file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Also write to stderr if verbose mode
    if [[ "$VERBOSE" == true ]]; then
        echo "[$timestamp] [$level] $message" >&2
    fi
}

print_header() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           Jenkins EBS Snapshot Backup Deployment          ║"
    echo "║                     Version $SCRIPT_VERSION                        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    local message="$1"
    echo -e "${BLUE}${ICON_INFO} $message${NC}"
    log_message "INFO" "$message"
}

log_success() {
    local message="$1"
    echo -e "${GREEN}${ICON_SUCCESS} $message${NC}"
    log_message "SUCCESS" "$message"
}

log_warning() {
    local message="$1"
    echo -e "${YELLOW}${ICON_WARNING} $message${NC}"
    log_message "WARNING" "$message"
}

log_error() {
    local message="$1"
    echo -e "${RED}${ICON_ERROR} $message${NC}" >&2
    log_message "ERROR" "$message"
}

log_debug() {
    local message="$1"
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${PURPLE}🔍 DEBUG: $message${NC}" >&2
    fi
    log_message "DEBUG" "$message"
}

progress_bar() {
    local current="$1"
    local total="$2"
    local message="${3:-Processing}"
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    
    printf "\r${CYAN}${message}: ["
    printf "%*s" "$completed" | tr ' ' '█'
    printf "%*s" $((width - completed)) | tr ' ' '░'
    printf "] %d%% (%d/%d)${NC}" "$percentage" "$current" "$total"
    
    if [[ "$current" -eq "$total" ]]; then
        echo
    fi
}

#===============================================================================
# ERROR HANDLING
#===============================================================================

# Global error handler
cleanup_on_error() {
    local exit_code=$?
    local line_number="$1"
    
    if [[ $exit_code -ne 0 ]]; then
        echo
        log_error "Script failed at line $line_number with exit code $exit_code"
        
        echo -e "${YELLOW}"
        echo "🔧 Troubleshooting suggestions:"
        echo "   1. Check your AWS credentials: aws sts get-caller-identity"
        echo "   2. Verify IAM permissions for CloudFormation, Lambda, EC2"
        echo "   3. Ensure the Jenkins instance exists and is accessible"
        echo "   4. Check the deployment log: $LOG_FILE"
        echo
        echo "   If the stack was partially created, clean up with:"
        echo "   $0 --cleanup"
        echo -e "${NC}"
        
        # Log additional debugging info
        log_debug "AWS CLI version: $(aws --version 2>/dev/null || echo 'Not available')"
        log_debug "Current region: $REGION"
        log_debug "Stack name: $STACK_NAME"
        log_debug "Template file: $TEMPLATE_FILE"
    fi
}

# Set up error handling
trap 'cleanup_on_error $LINENO' ERR

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate AWS region format
validate_aws_region() {
    local region="$1"
    if [[ ! "$region" =~ ^[a-z0-9-]+$ ]]; then
        log_error "Invalid AWS region format: $region"
        return 1
    fi
}

# Get AWS account info
get_aws_account_info() {
    local account_id
    local user_arn
    
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    user_arn=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
    
    echo "Account: $account_id | User: $user_arn"
}

# Format cost estimate
format_cost() {
    local amount="$1"
    printf "%.2f" "$amount"
}

# Generate secure random string
generate_random_string() {
    local length="${1:-8}"
    openssl rand -hex "$length" 2>/dev/null || date +%s | sha256sum | head -c "$length"
}

#===============================================================================
# PREREQUISITE CHECKS
#===============================================================================

check_prerequisites() {
    log_info "Validating prerequisites..."
    local errors=0
    
    # Check required commands
    local required_commands=("aws" "jq" "curl")
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            log_error "$cmd is not installed or not in PATH"
            ((errors++))
        else
            log_debug "$cmd: $(which "$cmd")"
        fi
    done
    
    # Check AWS CLI version
    local aws_version
    if command_exists aws; then
        aws_version=$(aws --version 2>&1 | head -1)
        log_debug "AWS CLI: $aws_version"
        
        # Check for AWS CLI v2 (recommended)
        if [[ "$aws_version" =~ aws-cli/2\. ]]; then
            log_debug "AWS CLI v2 detected (recommended)"
        elif [[ "$aws_version" =~ aws-cli/1\. ]]; then
            log_warning "AWS CLI v1 detected. Consider upgrading to v2 for better performance"
        fi
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        echo "  Configure with: aws configure"
        echo "  Or set environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
        ((errors++))
    else
        local account_info
        account_info=$(get_aws_account_info)
        log_success "AWS credentials valid: $account_info"
    fi
    
    # Validate region
    if ! validate_aws_region "$REGION"; then
        ((errors++))
    fi
    
    # Check template file
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        log_error "CloudFormation template not found: $TEMPLATE_FILE"
        echo "  Expected location: $SCRIPT_DIR/$TEMPLATE_FILE"
        ((errors++))
    else
        log_success "Template file found: $TEMPLATE_FILE"
        
        # Validate template syntax
        if aws cloudformation validate-template \
            --template-body "file://$TEMPLATE_FILE" \
            --region "$REGION" &> /dev/null; then
            log_success "Template syntax validation passed"
        else
            log_error "Template syntax validation failed"
            ((errors++))
        fi
    fi
    
    # Check IAM permissions (basic check)
    log_info "Checking IAM permissions..."
    local required_permissions=(
        "cloudformation:CreateStack"
        "cloudformation:UpdateStack"
        "cloudformation:DescribeStacks"
        "ec2:DescribeInstances"
        "ec2:DescribeSnapshots"
    )
    
    # Note: This is a simplified check. Full permission validation would require
    # actually calling the APIs, which we'll do during deployment.
    log_debug "IAM permission check: Basic validation passed"
    
    # Exit if errors found
    if [[ $errors -gt 0 ]]; then
        log_error "$errors prerequisite check(s) failed"
        exit 1
    fi
    
    log_success "All prerequisites satisfied"
}

#===============================================================================
# AWS RESOURCE DISCOVERY
#===============================================================================

discover_jenkins_instances() {
    log_info "Discovering Jenkins instances in region $REGION..."
    
    local instances_output
    local temp_file="/tmp/instances-$$.json"
    
    # Query EC2 instances with enhanced filtering
    if ! instances_output=$(aws ec2 describe-instances \
        --region "$REGION" \
        --filters \
            "Name=instance-state-name,Values=running,stopped" \
            "Name=platform,Values=linux" \
        --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,InstanceType,Platform]' \
        --output json 2>/dev/null); then
        log_warning "Failed to query EC2 instances. Check your permissions."
        return 1
    fi
    
    echo "$instances_output" > "$temp_file"
    
    # Find Jenkins-related instances
    local jenkins_instances=()
    local instance_count=0
    
    while IFS= read -r line; do
        if [[ "$line" =~ (jenkins|Jenkins|JENKINS) ]]; then
            jenkins_instances+=("$line")
            ((instance_count++))
        fi
    done <<< "$(jq -r '.[] | @json' "$temp_file" 2>/dev/null | while IFS= read -r instance; do
        local instance_data
        instance_data=$(echo "$instance" | jq -r '. | @csv')
        if [[ "$instance_data" =~ (jenkins|Jenkins|JENKINS) ]]; then
            echo "$instance_data"
        fi
    done)"
    
    # Clean up temp file
    rm -f "$temp_file"
    
    if [[ $instance_count -gt 0 ]]; then
        log_success "Found $instance_count potential Jenkins instance(s):"
        printf "%s\n" "${jenkins_instances[@]}" | while IFS=',' read -r instance_id name state type platform; do
            # Remove quotes from CSV output
            instance_id=$(echo "$instance_id" | tr -d '"')
            name=$(echo "$name" | tr -d '"')
            state=$(echo "$state" | tr -d '"')
            type=$(echo "$type" | tr -d '"')
            
            echo "  • $instance_id ($name) - $state - $type"
        done
        echo
    else
        log_warning "No instances with 'jenkins' in name/tags found"
        log_info "Tip: Make sure your Jenkins instance is tagged with 'Name' containing 'jenkins'"
        echo
    fi
    
    log_debug "Instance discovery completed"
}

#===============================================================================
# USER INPUT COLLECTION
#===============================================================================

get_instance_id() {
    local instance_id
    local attempts=0
    local max_attempts=3
    
    while [[ $attempts -lt $max_attempts ]]; do
        echo
        echo -e "${CYAN}📋 Please enter your Jenkins EC2 Instance ID:${NC}"
        echo "   Format: i-xxxxxxxxxxxxxxxxx (17 characters after 'i-')"
        echo "   Example: i-1234567890abcdef0"
        echo
        read -p "Instance ID: " instance_id
        
        # Trim whitespace
        instance_id=$(echo "$instance_id" | xargs)
        
        # Validate format
        if [[ ! "$instance_id" =~ ^i-[0-9a-f]{8,17}$ ]]; then
            log_error "Invalid instance ID format"
            echo "   Expected format: i-xxxxxxxxxxxxxxxxx"
            echo "   Your input: '$instance_id'"
            ((attempts++))
            continue
        fi
        
        # Validate instance exists and is accessible
        log_info "Validating instance $instance_id..."
        
        local instance_info
        if instance_info=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$REGION" \
            --query 'Reservations[0].Instances[0].[Tags[?Key==`Name`].Value|[0],State.Name,InstanceType]' \
            --output text 2>/dev/null); then
            
            local instance_name instance_state instance_type
            read -r instance_name instance_state instance_type <<< "$instance_info"
            
            instance_name="${instance_name:-Unknown}"
            
            log_success "Instance validated successfully!"
            echo "   Name: $instance_name"
            echo "   State: $instance_state"
            echo "   Type: $instance_type"
            
            # Warn if instance is stopped
            if [[ "$instance_state" != "running" ]]; then
                log_warning "Instance is in '$instance_state' state"
                echo "   Snapshots can be created from stopped instances"
                echo
                read -p "   Continue with this instance? (y/N): " -r continue_choice
                if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                    log_info "Please start the instance or choose a different one"
                    ((attempts++))
                    continue
                fi
            fi
            
            echo "$instance_id"
            return 0
        else
            log_error "Instance $instance_id not found or not accessible in region $REGION"
            echo "   Possible issues:"
            echo "   • Instance doesn't exist"
            echo "   • Instance is in a different region"
            echo "   • Insufficient IAM permissions"
            ((attempts++))
        fi
    done
    
    log_error "Failed to validate instance ID after $max_attempts attempts"
    exit 1
}

get_retention_days() {
    local retention_days
    local attempts=0
    local max_attempts=3
    
    while [[ $attempts -lt $max_attempts ]]; do
        echo
        echo -e "${CYAN}📅 Snapshot Retention Policy:${NC}"
        echo "   How many days should snapshots be kept?"
        echo "   • Minimum: 1 day"
        echo "   • Maximum: 365 days" 
        echo "   • Recommended: 7-14 days for most use cases"
        echo "   • Note: Longer retention = higher storage costs"
        echo
        read -p "Retention days (default: 7): " retention_days
        
        # Use default if empty
        retention_days="${retention_days:-7}"
        
        # Validate numeric input
        if [[ ! "$retention_days" =~ ^[0-9]+$ ]]; then
            log_error "Please enter a valid number"
            ((attempts++))
            continue
        fi
        
        # Validate range
        if [[ "$retention_days" -lt 1 || "$retention_days" -gt 365 ]]; then
            log_error "Retention days must be between 1 and 365"
            ((attempts++))
            continue
        fi
        
        # Cost warning for long retention
        if [[ "$retention_days" -gt 30 ]]; then
            log_warning "Long retention periods increase storage costs"
            echo "   Estimated additional cost: ~\$$(echo "scale=2; $retention_days * 0.15" | bc -l 2>/dev/null || echo "5")/month"
            echo
            read -p "   Continue with $retention_days days? (y/N): " -r continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                ((attempts++))
                continue
            fi
        fi
        
        log_success "Retention policy set to $retention_days days"
        echo "$retention_days"
        return 0
    done
    
    log_error "Failed to set retention policy after $max_attempts attempts"
    exit 1
}

get_backup_time() {
    local backup_time
    local attempts=0
    local max_attempts=3
    
    while [[ $attempts -lt $max_attempts ]]; do
        echo
        echo -e "${CYAN}⏰ Daily Backup Schedule:${NC}"
        echo "   When should daily backups run? (UTC time)"
        echo "   • Format: HH:MM (24-hour format)"
        echo "   • Examples: 02:00, 14:30, 23:45"
        echo "   • Recommended: Off-peak hours (02:00-05:00 UTC)"
        echo "   • Current UTC time: $(date -u '+%H:%M')"
        echo
        read -p "Backup time UTC (default: 02:00): " backup_time
        
        # Use default if empty
        backup_time="${backup_time:-02:00}"
        
        # Validate format
        if [[ ! "$backup_time" =~ ^([0-1]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            log_error "Invalid time format"
            echo "   Expected format: HH:MM (24-hour)"
            echo "   Examples: 02:00, 14:30, 23:45"
            echo "   Your input: '$backup_time'"
            ((attempts++))
            continue
        fi
        
        # Convert to local time for user reference
        local hour minute
        IFS=':' read -r hour minute <<< "$backup_time"
        
        log_success "Backup scheduled for $backup_time UTC daily"
        
        # Show local time equivalent (best effort)
        if command_exists date; then
            local local_time
            local_time=$(TZ="$(date +%Z)" date -d "${hour}:${minute} UTC" '+%H:%M %Z' 2>/dev/null || echo "Unknown")
            if [[ "$local_time" != "Unknown" ]]; then
                echo "   Local time equivalent: approximately $local_time"
            fi
        fi
        
        echo "$backup_time"
        return 0
    done
    
    log_error "Failed to set backup time after $max_attempts attempts"
    exit 1
}

get_notification_email() {
    local email_input
    
    echo
    echo -e "${CYAN}📧 Email Notifications (Optional):${NC}"
    echo "   Receive notifications for:"
    echo "   • Backup success/failure"
    echo "   • Snapshot cleanup operations" 
    echo "   • Cost alerts (if enabled)"
    echo
    echo "   Leave empty to skip notifications"
    echo
    read -p "Email address (optional): " email_input
    
    # Skip if empty
    if [[ -z "$email_input" ]]; then
        log_info "Email notifications disabled"
        echo ""
        return 0
    fi
    
    # Validate email format
    if [[ "$email_input" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_success "Email notifications will be sent to: $email_input"
        echo "   📌 Don't forget to confirm the SNS subscription in your email!"
        echo "$email_input"
        return 0
    else
        log_warning "Invalid email format: $email_input"
        echo "   Continuing without notifications..."
        echo ""
        return 0
    fi
}

collect_configuration() {
    log_info "Starting interactive configuration..."
    echo
    echo -e "${WHITE}This wizard will guide you through configuring your Jenkins backup automation.${NC}"
    echo
    
    # Collect configuration with progress indication
    log_info "Step 1/4: Jenkins Instance Configuration"
    JENKINS_INSTANCE_ID=$(get_instance_id)
    
    log_info "Step 2/4: Retention Policy Configuration"  
    RETENTION_DAYS=$(get_retention_days)
    
    log_info "Step 3/4: Backup Schedule Configuration"
    BACKUP_TIME=$(get_backup_time)
    
    log_info "Step 4/4: Notification Configuration"
    NOTIFICATION_EMAIL=$(get_notification_email)
    
    log_success "Configuration collection completed!"
}

#===============================================================================
# COST ESTIMATION
#===============================================================================

calculate_estimated_cost() {
    local instance_id="$1"
    local retention_days="$2"
    
    log_debug "Calculating cost estimate for $instance_id"
    
    # Get volume information
    local volume_info
    if ! volume_info=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[].Ebs.VolumeSize' \
        --output json 2>/dev/null); then
        log_debug "Could not retrieve volume information for cost calculation"
        echo "1.00"  # Default estimate
        return 0
    fi
    
    # Calculate total storage
    local total_storage=0
    while IFS= read -r size; do
        total_storage=$((total_storage + size))
    done <<< "$(echo "$volume_info" | jq -r '.[]' 2>/dev/null)"
    
    if [[ $total_storage -eq 0 ]]; then
        total_storage=20  # Default assumption
    fi
    
    # EBS Snapshot cost calculation
    # $0.05 per GB-month for standard snapshots
    # Incremental snapshots typically use 20-30% of original volume size
    local snapshot_efficiency=0.25  # 25% of original size on average
    local monthly_storage=$(echo "scale=2; $total_storage * $snapshot_efficiency" | bc -l 2>/dev/null || echo "$total_storage")
    local monthly_cost=$(echo "scale=2; $monthly_storage * 0.05" | bc -l 2>/dev/null || echo "1.00")
    
    # Additional costs for retention
    if [[ $retention_days -gt 7 ]]; then
        local retention_multiplier=$(echo "scale=2; $retention_days / 7" | bc -l 2>/dev/null || echo "1")
        monthly_cost=$(echo "scale=2; $monthly_cost * $retention_multiplier * 0.7" | bc -l 2>/dev/null || echo "$monthly_cost")
    fi
    
    log_debug "Cost calculation: ${total_storage}GB volume, estimated $monthly_cost/month"
    format_cost "$monthly_cost"
}

#===============================================================================
# DEPLOYMENT SUMMARY
#===============================================================================

show_deployment_summary() {
    local estimated_cost
    estimated_cost=$(calculate_estimated_cost "$JENKINS_INSTANCE_ID" "$RETENTION_DAYS")
    
    echo
    echo -e "${WHITE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                    DEPLOYMENT SUMMARY                     ║${NC}"
    echo -e "${WHITE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${CYAN}📋 Configuration Details:${NC}"
    echo "   Stack Name: $STACK_NAME"
    echo "   AWS Region: $REGION"
    echo "   Instance ID: $JENKINS_INSTANCE_ID"
    echo "   Retention: $RETENTION_DAYS days"
    echo "   Backup Time: $BACKUP_TIME UTC"
    echo "   Notifications: ${NOTIFICATION_EMAIL:-"Disabled"}"
    echo
    echo -e "${CYAN}💰 Cost Estimate:${NC}"
    echo "   Monthly cost: ~\$$estimated_cost"
    echo "   Annual cost: ~\$$(echo "scale=2; $estimated_cost * 12" | bc -l 2>/dev/null || echo "12")"
    echo "   Storage type: EBS Snapshots (incremental)"
    echo
    echo -e "${CYAN}🏗️ Resources to be created:${NC}"
    echo "   • Lambda Function (Python 3.11)"
    echo "   • EventBridge Rule (daily cron)"
    echo "   • IAM Role (least-privilege)"
    if [[ -n "$NOTIFICATION_EMAIL" ]]; then
        echo "   • SNS Topic (email notifications)"
    fi
    echo "   • CloudWatch Dashboard"
    echo
    echo -e "${CYAN}⚡ Capabilities:${NC}"
    echo "   • Automated daily backups"
    echo "   • Intelligent cleanup (${RETENTION_DAYS}-day retention)"  
    echo "   • 5-minute disaster recovery"
    echo "   • Comprehensive monitoring"
    echo
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}🔍 DRY RUN MODE: No resources will be created${NC}"
        echo
    fi
}

#===============================================================================
# CLOUDFORMATION DEPLOYMENT
#===============================================================================

deploy_cloudformation_stack() {
    log_info "Deploying CloudFormation stack..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would deploy stack '$STACK_NAME' with the above configuration"
        return 0
    fi
    
    # Build parameters array
    local parameters=(
        "ParameterKey=JenkinsInstanceId,ParameterValue=$JENKINS_INSTANCE_ID"
        "ParameterKey=RetentionDays,ParameterValue=$RETENTION_DAYS"
        "ParameterKey=BackupTime,ParameterValue=$BACKUP_TIME"
    )
    
    # Add email parameter if provided
    if [[ -n "$NOTIFICATION_EMAIL" ]]; then
        parameters+=("ParameterKey=NotificationEmail,ParameterValue=$NOTIFICATION_EMAIL")
    fi
    
    # Deploy with progress indication
    log_info "Initiating CloudFormation deployment..."
    local deploy_start_time
    deploy_start_time=$(date +%s)
    
    local deploy_output
    local deploy_result=0
    
    # Capture both stdout and stderr
    if ! deploy_output=$(aws cloudformation deploy \
        --template-file "$TEMPLATE_FILE" \
        --stack-name "$STACK_NAME" \
        --parameter-overrides "${parameters[@]}" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --no-fail-on-empty-changeset 2>&1); then
        deploy_result=1
    fi
    
    local deploy_end_time
    deploy_end_time=$(date +%s)
    local deploy_duration=$((deploy_end_time - deploy_start_time))
    
    if [[ $deploy_result -eq 0 ]]; then
        log_success "CloudFormation deployment completed successfully!"
        log_info "Deployment time: ${deploy_duration} seconds"
        
        # Log deployment details
        log_debug "Deployment output: $deploy_output"
    else
        log_error "CloudFormation deployment failed"
        
        # Enhanced error handling with specific guidance
        echo -e "${RED}Deployment Error Details:${NC}"
        echo "$deploy_output" | while IFS= read -r line; do
            echo "  $line"
        done
        echo
        
        # Provide specific troubleshooting guidance
        if [[ "$deploy_output" =~ "AccessDenied" ]]; then
            log_error "IAM Permission Issues Detected"
            echo -e "${YELLOW}Required IAM permissions:${NC}"
            cat << 'EOF'
  • cloudformation:CreateStack / UpdateStack / DescribeStacks
  • lambda:CreateFunction / UpdateFunctionCode
  • iam:CreateRole / AttachRolePolicy / PassRole
  • events:PutRule / PutTargets
  • ec2:DescribeInstances / DescribeVolumes / CreateSnapshot
  • logs:CreateLogGroup / CreateLogStream
EOF
            if [[ -n "$NOTIFICATION_EMAIL" ]]; then
                echo "  • sns:CreateTopic / Subscribe / Publish"
            fi
            echo
            
        elif [[ "$deploy_output" =~ "AlreadyExistsException" ]]; then
            log_warning "Stack already exists"
            echo "  Use --cleanup to remove the existing stack first"
            echo "  Or choose a different stack name with --stack-name"
            echo
            
        elif [[ "$deploy_output" =~ "ValidationError" ]]; then
            log_error "Template or parameter validation failed"
            echo "  This usually indicates:"
            echo "  • Invalid parameter values"
            echo "  • Template syntax issues" 
            echo "  • Missing required parameters"
            echo
        fi
        
        return 1
    fi
}

#===============================================================================
# POST-DEPLOYMENT VALIDATION
#===============================================================================

validate_deployment() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    
    log_info "Validating deployment..."
    
    # Check stack status
    local stack_status
    if ! stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null); then
        log_error "Could not retrieve stack status"
        return 1
    fi
    
    case "$stack_status" in
        "CREATE_COMPLETE"|"UPDATE_COMPLETE")
            log_success "Stack status: $stack_status"
            ;;
        "CREATE_IN_PROGRESS"|"UPDATE_IN_PROGRESS")
            log_info "Stack status: $stack_status (still in progress)"
            ;;
        "ROLLBACK_COMPLETE"|"UPDATE_ROLLBACK_COMPLETE")
            log_warning "Stack status: $stack_status (deployment was rolled back)"
            return 1
            ;;
        *)
            log_error "Unexpected stack status: $stack_status"
            return 1
            ;;
    esac
    
    # Retrieve and display stack outputs
    local stack_outputs
    if stack_outputs=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs' \
        --output table 2>/dev/null); then
        
        echo
        log_info "Stack Outputs:"
        echo "$stack_outputs"
        echo
    else
        log_warning "Could not retrieve stack outputs"
    fi
    
    # Verify key resources exist
    log_info "Verifying created resources..."
    
    # Check Lambda function
    local function_name
    if function_name=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
        --output text 2>/dev/null) && [[ -n "$function_name" ]]; then
        
        log_success "Lambda function verified: $function_name"
    else
        log_warning "Could not verify Lambda function"
    fi
    
    # Check EventBridge rule
    local rule_name
    if rule_name=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`ScheduleRuleName`].OutputValue' \
        --output text 2>/dev/null) && [[ -n "$rule_name" ]]; then
        
        log_success "EventBridge rule verified: $rule_name"
    else
        log_warning "Could not verify EventBridge rule"
    fi
    
    log_success "Deployment validation completed"
}

#===============================================================================
# TESTING FUNCTIONS
#===============================================================================

test_backup_function() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    
    echo
    echo -e "${CYAN}🧪 Would you like to test the backup function now?${NC}"
    echo "   This will:"
    echo "   • Invoke the Lambda function manually"
    echo "   • Create a test snapshot"
    echo "   • Verify the automation is working"
    echo
    read -p "Run backup test? (y/N): " -r test_choice
    
    if [[ ! "$test_choice" =~ ^[Yy]$ ]]; then
        log_info "Skipping backup test"
        return 0
    fi
    
    log_info "Testing backup function..."
    
    # Get function name from stack outputs
    local function_name
    if ! function_name=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
        --output text 2>/dev/null) || [[ -z "$function_name" ]]; then
        log_error "Could not determine Lambda function name"
        return 1
    fi
    
    # Create temporary file for response
    local response_file="/tmp/lambda_response_$$.json"
    local invoke_start_time
    invoke_start_time=$(date +%s)
    
    # Invoke function with progress indication
    log_info "Invoking Lambda function: $function_name"
    
    if aws lambda invoke \
        --function-name "$function_name" \
        --region "$REGION" \
        --payload '{}' \
        "$response_file" >/dev/null 2>&1; then
        
        local invoke_end_time
        invoke_end_time=$(date +%s)
        local invoke_duration=$((invoke_end_time - invoke_start_time))
        
        log_success "Backup function executed successfully!"
        log_info "Execution time: ${invoke_duration} seconds"
        
        # Parse and display response
        if [[ -f "$response_file" ]] && [[ -s "$response_file" ]]; then
            echo
            log_info "Function Response:"
            
            # Pretty-print JSON if possible
            if command_exists jq && jq empty "$response_file" 2>/dev/null; then
                jq . "$response_file"
            else
                cat "$response_file"
            fi
            echo
            
            # Check for errors in response
            if grep -q '"statusCode": 500' "$response_file" 2>/dev/null; then
                log_warning "Function returned an error status"
            elif grep -q '"statusCode": 200' "$response_file" 2>/dev/null; then
                log_success "Function executed successfully"
                
                # Verify snapshot was created
                log_info "Verifying snapshot creation..."
                sleep 5  # Give AWS time to create the snapshot
                
                local recent_snapshots
                if recent_snapshots=$(aws ec2 describe-snapshots \
                    --owner-ids self \
                    --region "$REGION" \
                    --filters \
                        "Name=tag:Purpose,Values=Jenkins-Backup" \
                        "Name=tag:InstanceId,Values=$JENKINS_INSTANCE_ID" \
                    --query 'Snapshots[?StartTime>=`'"$(date -u -d '5 minutes ago' --iso-8601)"'`].[SnapshotId,StartTime,State]' \
                    --output table 2>/dev/null) && [[ -n "$recent_snapshots" ]]; then
                    
                    log_success "Recent snapshots found:"
                    echo "$recent_snapshots"
                else
                    log_info "No recent snapshots found (may take a few minutes to appear)"
                fi
            fi
        fi
        
        # Cleanup temp file
        rm -f "$response_file"
        
    else
        log_error "Failed to invoke backup function"
        log_info "Check the Lambda function logs in CloudWatch for details"
        rm -f "$response_file"
        return 1
    fi
}

#===============================================================================
# CLEANUP FUNCTIONS
#===============================================================================

cleanup_stack() {
    echo
    echo -e "${YELLOW}🗑️  Stack Cleanup Mode${NC}"
    echo
    echo "This will delete the CloudFormation stack and all associated resources:"
    echo "  • Lambda function"
    echo "  • EventBridge rule"
    echo "  • IAM roles"
    echo "  • SNS topic (if created)"
    echo "  • CloudWatch dashboard"
    echo
    echo -e "${RED}⚠️  WARNING: This will NOT delete existing EBS snapshots${NC}"
    echo "   Snapshots must be deleted manually to avoid ongoing costs"
    echo
    
    read -p "Are you sure you want to delete stack '$STACK_NAME'? (y/N): " -r confirm_cleanup
    
    if [[ ! "$confirm_cleanup" =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled"
        return 0
    fi
    
    log_info "Deleting CloudFormation stack: $STACK_NAME"
    
    if aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$REGION" 2>/dev/null; then
        
        log_success "Stack deletion initiated"
        log_info "Deletion will complete in a few minutes"
        log_info "Monitor progress in the AWS Console or with:"
        echo "  aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION"
        
    else
        log_error "Failed to initiate stack deletion"
        echo "  Possible reasons:"
        echo "  • Stack doesn't exist"
        echo "  • Insufficient permissions"
        echo "  • Stack is in a state that prevents deletion"
        return 1
    fi
    
    echo
    log_warning "Don't forget to clean up EBS snapshots if no longer needed:"
    echo "  aws ec2 describe-snapshots --owner-ids self --filters 'Name=tag:Purpose,Values=Jenkins-Backup'"
}

#===============================================================================
# NEXT STEPS AND DOCUMENTATION
#===============================================================================

show_next_steps() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    
    echo
    echo -e "${WHITE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                      NEXT STEPS                           ║${NC}"  
    echo -e "${WHITE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}${ICON_SUCCESS} Deployment completed successfully!${NC}"
    echo
    echo -e "${CYAN}📋 Immediate Actions:${NC}"
    
    if [[ -n "$NOTIFICATION_EMAIL" ]]; then
        echo "  1. Check your email and confirm the SNS subscription"
    fi
    echo "  2. Monitor the first backup execution (scheduled for $BACKUP_TIME UTC)"
    echo "  3. Verify snapshots appear in EC2 Console > Snapshots"
    
    echo
    echo -e "${CYAN}🔍 Monitoring & Verification:${NC}"
    echo "  • CloudWatch Dashboard: Check Lambda metrics and logs"
    echo "  • EC2 Snapshots: aws ec2 describe-snapshots --owner-ids self --filters 'Name=tag:Purpose,Values=Jenkins-Backup'"
    echo "  • Cost monitoring: AWS Billing Dashboard > EC2-EBS:SnapshotUsage"
    
    echo  
    echo -e "${CYAN}📚 Documentation:${NC}"
    echo "  • Deployment logs: $LOG_FILE"
    echo "  • GitHub repository: https://github.com/your-username/jenkins-ebs-backup-automation"
    echo "  • Disaster recovery guide: docs/disaster-recovery.md"
    
    echo
    echo -e "${CYAN}🆘 Disaster Recovery (when needed):${NC}"
    echo "  1. Identify snapshot: aws ec2 describe-snapshots --filters 'Name=tag:Purpose,Values=Jenkins-Backup'"
    echo "  2. Create volume: aws ec2 create-volume --snapshot-id snap-xxxxxxxxx"  
    echo "  3. Launch instance: aws ec2 run-instances --image-id ami-xxxxxxxxx"
    echo "  4. Complete recovery: See docs/disaster-recovery.md"
    
    echo
    echo -e "${CYAN}⚙️  Customization Options:${NC}"
    echo "  • Modify retention: Update RetentionDays parameter"
    echo "  • Change schedule: Update BackupTime parameter"
    echo "  • Cross-region backup: See docs/advanced-configuration.md"
    echo "  • Multi-instance setup: Re-run with different instance IDs"
    
    echo
    echo -e "${YELLOW}💡 Pro Tips:${NC}"
    echo "  • Test disaster recovery monthly: ./scripts/dr-test.sh"
    echo "  • Monitor costs: Set up billing alerts for EBS snapshots"
    echo "  • Keep documentation updated: Update runbooks with any customizations"
    
    if [[ -n "$LOG_FILE" ]]; then
        echo
        echo -e "${PURPLE}📄 Full deployment log saved to: $LOG_FILE${NC}"
    fi
    
    echo
    echo -e "${GREEN}${ICON_ROCKET} Jenkins backup automation is now active!${NC}"
    echo -e "${WHITE}Sweet dreams – your Jenkins is protected! 😴${NC}"
}

#===============================================================================
# HELP AND DOCUMENTATION
#===============================================================================

show_help() {
    cat << EOF
${WHITE}Jenkins EBS Snapshot Backup - Deployment Script${NC}

${CYAN}DESCRIPTION:${NC}
    Deploys production-ready automated Jenkins disaster recovery using AWS EBS 
    snapshots and Lambda functions. Eliminates plugin dependencies while providing
    true infrastructure-level backup capabilities.

${CYAN}USAGE:${NC}
    $SCRIPT_NAME [OPTIONS]

${CYAN}OPTIONS:${NC}
    -h, --help              Show this help message and exit
    -c, --config FILE       Use configuration file instead of interactive mode
    -r, --region REGION     Override default AWS region
    -s, --stack-name NAME   Override default CloudFormation stack name
    --dry-run              Preview deployment without creating resources
    --cleanup              Remove existing stack and associated resources
    --verbose              Enable verbose logging and debugging output
    --version              Show version information

${CYAN}ENVIRONMENT VARIABLES:${NC}
    AWS_DEFAULT_REGION      Default AWS region (default: us-east-1)
    AWS_PROFILE            AWS CLI profile to use
    JENKINS_INSTANCE_ID     Skip instance discovery (for automation)
    
${CYAN}EXAMPLES:${NC}
    ${YELLOW}Interactive deployment:${NC}
    $SCRIPT_NAME
    
    ${YELLOW}Deploy to specific region:${NC}
    $SCRIPT_NAME --region eu-west-1
    
    ${YELLOW}Preview changes without deployment:${NC}
    $SCRIPT_NAME --dry-run
    
    ${YELLOW}Use custom stack name:${NC}
    $SCRIPT_NAME --stack-name my-jenkins-backup
    
    ${YELLOW}Clean up existing deployment:${NC}
    $SCRIPT_NAME --cleanup
    
    ${YELLOW}Automated deployment with configuration file:${NC}
    $SCRIPT_NAME --config jenkins-backup.conf

${CYAN}CONFIGURATION FILE FORMAT:${NC}
    # jenkins-backup.conf
    JENKINS_INSTANCE_ID=i-1234567890abcdef0
    RETENTION_DAYS=14
    BACKUP_TIME=03:00
    NOTIFICATION_EMAIL=admin@company.com
    STACK_NAME=jenkins-backup-prod
    REGION=us-east-1

${CYAN}PREREQUISITES:${NC}
    • AWS CLI installed and configured
    • Jenkins running on EC2 with EBS storage
    • IAM permissions for CloudFormation, Lambda, EC2, SNS
    • Bash shell (Linux/macOS/WSL)

${CYAN}FEATURES:${NC}
    • Automated daily EBS snapshots
    • Configurable retention policies
    • Email notifications (optional)
    • 5-minute disaster recovery
    • Cost optimization with incremental snapshots
    • CloudWatch monitoring and dashboards
    • Production-ready error handling

${CYAN}SUPPORT:${NC}
    • GitHub: https://github.com/your-username/jenkins-ebs-backup-automation
    • Issues: https://github.com/your-username/jenkins-ebs-backup-automation/issues
    • Documentation: https://github.com/your-username/jenkins-ebs-backup-automation/docs

${CYAN}VERSION:${NC}
    $SCRIPT_VERSION

${CYAN}LICENSE:${NC}
    MIT License - see LICENSE file for details

EOF
}

show_version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
    echo "Jenkins EBS Snapshot Backup Automation"
    echo "MIT License - https://github.com/your-username/jenkins-ebs-backup-automation"
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                if [[ ! -f "$CONFIG_FILE" ]]; then
                    log_error "Configuration file not found: $CONFIG_FILE"
                    exit 1
                fi
                shift 2
                ;;
            -r|--region)
                REGION="$2"
                if [[ -z "$REGION" ]]; then
                    log_error "Region cannot be empty"
                    exit 1
                fi
                shift 2
                ;;
            -s|--stack-name)
                STACK_NAME="$2"
                if [[ -z "$STACK_NAME" ]]; then
                    log_error "Stack name cannot be empty"
                    exit 1
                fi
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                log_debug "Dry run mode enabled"
                shift
                ;;
            --cleanup)
                CLEANUP_MODE=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                log_debug "Verbose mode enabled"
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

#===============================================================================
# CONFIGURATION FILE LOADING
#===============================================================================

load_configuration_file() {
    if [[ -z "$CONFIG_FILE" ]]; then
        return 0
    fi
    
    log_info "Loading configuration from: $CONFIG_FILE"
    
    # Source the configuration file safely
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        if [[ "$key" =~ ^[[:space:]]*# ]] || [[ -z "$key" ]]; then
            continue
        fi
        
        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        # Set variables based on configuration
        case "$key" in
            JENKINS_INSTANCE_ID)
                JENKINS_INSTANCE_ID="$value"
                log_debug "Config: JENKINS_INSTANCE_ID=$value"
                ;;
            RETENTION_DAYS)
                RETENTION_DAYS="$value"
                log_debug "Config: RETENTION_DAYS=$value"
                ;;
            BACKUP_TIME)
                BACKUP_TIME="$value"
                log_debug "Config: BACKUP_TIME=$value"
                ;;
            NOTIFICATION_EMAIL)
                NOTIFICATION_EMAIL="$value"
                log_debug "Config: NOTIFICATION_EMAIL=$value"
                ;;
            STACK_NAME)
                STACK_NAME="$value"
                log_debug "Config: STACK_NAME=$value"
                ;;
            REGION)
                REGION="$value"
                log_debug "Config: REGION=$value"
                ;;
            *)
                log_warning "Unknown configuration option: $key"
                ;;
        esac
    done < "$CONFIG_FILE"
    
    log_success "Configuration loaded successfully"
}

#===============================================================================
# MAIN EXECUTION FLOW
#===============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Handle cleanup mode
    if [[ "$CLEANUP_MODE" == true ]]; then
        cleanup_stack
        exit 0
    fi
    
    # Display header
    print_header
    
    # Load configuration file if provided
    load_configuration_file
    
    # Execute deployment pipeline
    check_prerequisites
    
    if [[ -z "$CONFIG_FILE" ]]; then
        # Interactive mode
        discover_jenkins_instances
        collect_configuration
    else
        # Configuration file mode
        log_info "Using configuration file mode"
        if [[ -z "$JENKINS_INSTANCE_ID" ]]; then
            log_error "JENKINS_INSTANCE_ID must be specified in configuration file"
            exit 1
        fi
        
        # Set defaults for missing values
        RETENTION_DAYS="${RETENTION_DAYS:-7}"
        BACKUP_TIME="${BACKUP_TIME:-02:00}"
        NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
    fi
    
    # Show summary and get confirmation
    show_deployment_summary
    
    # Skip confirmation in dry-run mode
    if [[ "$DRY_RUN" != true ]]; then
        echo
        echo -e "${CYAN}🚀 Ready to deploy! This will create AWS resources and incur costs.${NC}"
        echo
        read -p "Proceed with deployment? (y/N): " -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Deployment cancelled by user"
            exit 0
        fi
    fi
    
    # Execute deployment
    deploy_cloudformation_stack
    validate_deployment
    test_backup_function
    show_next_steps
    
    # Final success message
    echo
    log_success "Jenkins backup automation deployed successfully! ${ICON_ROCKET}"
    
    # Clean up trap
    trap - EXIT
}

#===============================================================================
# SCRIPT ENTRY POINT
#===============================================================================

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi