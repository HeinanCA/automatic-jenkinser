#!/bin/bash
#
# Jenkins Disaster Recovery Script
#
# This script automates the disaster recovery process for Jenkins using EBS snapshots.
# It helps you quickly identify, create volumes from snapshots, and launch recovery instances.
#
# Usage:
#   ./disaster-recovery.sh [OPTIONS] [SNAPSHOT_ID]
#
# Options:
#   -h, --help              Show help message
#   -l, --list              List available snapshots
#   -i, --interactive       Interactive recovery mode
#   -r, --region REGION     AWS region (default: us-east-1)
#   --instance-type TYPE    EC2 instance type (default: t3.medium)
#   --key-name NAME         EC2 key pair name (required for new instance)
#   --security-group ID     Security group ID (required for new instance)
#   --subnet-id ID          Subnet ID (required for new instance)
#   --dry-run              Preview actions without execution
#
# Examples:
#   ./disaster-recovery.sh --list
#   ./disaster-recovery.sh --interactive
#   ./disaster-recovery.sh snap-1234567890abcdef0 --key-name my-key --security-group sg-123 --subnet-id subnet-456
#

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
readonly DEFAULT_INSTANCE_TYPE="t3.medium"

# Runtime variables
REGION="$DEFAULT_REGION"
INSTANCE_TYPE="$DEFAULT_INSTANCE_TYPE"
SNAPSHOT_ID=""
KEY_NAME=""
SECURITY_GROUP=""
SUBNET_ID=""
DRY_RUN=false
LIST_MODE=false
INTERACTIVE_MODE=false

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Icons
readonly ICON_SUCCESS="✅"
readonly ICON_ERROR="❌"
readonly ICON_WARNING="⚠️"
readonly ICON_INFO="ℹ️"

#===============================================================================
# LOGGING FUNCTIONS
#===============================================================================

log_info() {
    echo -e "${BLUE}${ICON_INFO} $1${NC}"
}

log_success() {
    echo -e "${GREEN}${ICON_SUCCESS} $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}${ICON_WARNING} $1${NC}"
}

log_error() {
    echo -e "${RED}${ICON_ERROR} $1${NC}" >&2
}

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

show_help() {
    cat << EOF
${BLUE}Jenkins Disaster Recovery Script${NC}

${YELLOW}DESCRIPTION:${NC}
    Automates Jenkins disaster recovery using EBS snapshots. Helps you quickly
    identify backup snapshots and launch recovery instances with minimal downtime.

${YELLOW}USAGE:${NC}
    $SCRIPT_NAME [OPTIONS] [SNAPSHOT_ID]

${YELLOW}OPTIONS:${NC}
    -h, --help              Show this help message
    -l, --list              List available Jenkins backup snapshots
    -i, --interactive       Interactive recovery mode (recommended)
    -r, --region REGION     AWS region (default: $DEFAULT_REGION)
    --instance-type TYPE    EC2 instance type (default: $DEFAULT_INSTANCE_TYPE)
    --key-name NAME         EC2 key pair name (required for new instance)
    --security-group ID     Security group ID (required for new instance)
    --subnet-id ID          Subnet ID (required for new instance)
    --dry-run              Preview actions without execution

${YELLOW}EXAMPLES:${NC}
    ${GREEN}List available snapshots:${NC}
    $SCRIPT_NAME --list

    ${GREEN}Interactive recovery (recommended):${NC}
    $SCRIPT_NAME --interactive

    ${GREEN}Direct recovery from snapshot:${NC}
    $SCRIPT_NAME snap-1234567890abcdef0 \\
      --key-name my-jenkins-key \\
      --security-group sg-123456789 \\
      --subnet-id subnet-987654321

    ${GREEN}Preview recovery actions:${NC}
    $SCRIPT_NAME --interactive --dry-run

${YELLOW}PREREQUISITES:${NC}
    • AWS CLI installed and configured
    • Appropriate IAM permissions for EC2 operations
    • Knowledge of VPC configuration (security groups, subnets)
    • EC2 key pair for SSH access

${YELLOW}RECOVERY PROCESS:${NC}
    1. Identify the appropriate snapshot
    2. Create EBS volume from snapshot
    3. Launch new EC2 instance
    4. Attach volume to instance
    5. Verify Jenkins functionality
    6. Update DNS/load balancer configuration

EOF
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws >/dev/null 2>&1; then
        log_error "AWS CLI is not installed"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured"
        exit 1
    fi
    
    # Check region accessibility
    if ! aws ec2 describe-regions --region-names "$REGION" >/dev/null 2>&1; then
        log_error "Cannot access region: $REGION"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

#===============================================================================
# SNAPSHOT MANAGEMENT
#===============================================================================

list_snapshots() {
    log_info "Listing available Jenkins backup snapshots in region: $REGION"
    
    local snapshots
    if ! snapshots=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --region "$REGION" \
        --filters "Name=tag:Purpose,Values=Jenkins-Backup" \
        --query 'Snapshots[*].[SnapshotId,StartTime,State,VolumeSize,Description,Tags[?Key==`Name`].Value|[0]]' \
        --output table 2>/dev/null); then
        log_error "Failed to retrieve snapshots"
        exit 1
    fi
    
    if [[ -z "$snapshots" || "$snapshots" == *"None"* ]]; then
        log_warning "No Jenkins backup snapshots found"
        echo "Make sure:"
        echo "  • Snapshots exist in the specified region"
        echo "  • Snapshots are tagged with Purpose=Jenkins-Backup"
        echo "  • You have permissions to describe snapshots"
        exit 1
    fi
    
    echo
    echo "Available Jenkins Backup Snapshots:"
    echo "$snapshots"
    echo
    
    # Show additional details
    local snapshot_count
    snapshot_count=$(echo "$snapshots" | grep -c snap- || echo "0")
    log_info "Found $snapshot_count backup snapshot(s)"
    
    # Show estimated costs
    log_info "Storage costs: ~\$0.05 per GB-month for snapshot storage"
}

select_snapshot_interactive() {
    log_info "Interactive snapshot selection"
    
    # Get snapshots as JSON for processing
    local snapshots_json
    if ! snapshots_json=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --region "$REGION" \
        --filters "Name=tag:Purpose,Values=Jenkins-Backup" \
        --query 'Snapshots[*].[SnapshotId,StartTime,State,VolumeSize,Description]' \
        --output json 2>/dev/null); then
        log_error "Failed to retrieve snapshots"
        exit 1
    fi
    
    if [[ "$snapshots_json" == "[]" ]]; then
        log_error "No Jenkins backup snapshots found"
        exit 1
    fi
    
    echo
    echo "Select a snapshot for recovery:"
    echo
    
    local counter=1
    local snapshot_ids=()
    
    # Parse and display snapshots
    echo "$snapshots_json" | jq -r '.[] | @csv' | while IFS=',' read -r snapshot_id start_time state volume_size description; do
        # Remove quotes from CSV output
        snapshot_id=$(echo "$snapshot_id" | tr -d '"')
        start_time=$(echo "$start_time" | tr -d '"')
        state=$(echo "$state" | tr -d '"')
        volume_size=$(echo "$volume_size" | tr -d '"')
        description=$(echo "$description" | tr -d '"')
        
        # Format the start time for display
        local formatted_time
        formatted_time=$(date -d "$start_time" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$start_time")
        
        echo "$counter. $snapshot_id"
        echo "   Created: $formatted_time"
        echo "   State: $state"
        echo "   Size: ${volume_size}GB"
        echo "   Description: $description"
        echo
        
        snapshot_ids+=("$snapshot_id")
        ((counter++))
    done
    
    # Get user selection
    local selection
    while true; do
        read -p "Enter selection number (1-$((counter-1))): " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && \
           [[ "$selection" -ge 1 ]] && \
           [[ "$selection" -le $((counter-1)) ]]; then
            SNAPSHOT_ID="${snapshot_ids[$((selection-1))]}"
            log_success "Selected snapshot: $SNAPSHOT_ID"
            break
        else
            log_error "Invalid selection. Please enter a number between 1 and $((counter-1))"
        fi
    done
}

validate_snapshot() {
    local snapshot_id="$1"
    
    log_info "Validating snapshot: $snapshot_id"
    
    # Check if snapshot exists and get details
    local snapshot_info
    if ! snapshot_info=$(aws ec2 describe-snapshots \
        --snapshot-ids "$snapshot_id" \
        --region "$REGION" \
        --query 'Snapshots[0].[State,VolumeSize,Encrypted,Description]' \
        --output text 2>/dev/null); then
        log_error "Snapshot $snapshot_id not found or not accessible"
        exit 1
    fi
    
    local state volume_size encrypted description
    read -r state volume_size encrypted description <<< "$snapshot_info"
    
    if [[ "$state" != "completed" ]]; then
        log_error "Snapshot is not in 'completed' state: $state"
        exit 1
    fi
    
    log_success "Snapshot validation passed"
    echo "  State: $state"
    echo "  Volume Size: ${volume_size}GB"
    echo "  Encrypted: $encrypted"
    echo "  Description: $description"
    echo
}

#===============================================================================
# RECOVERY PROCESS
#===============================================================================

get_recovery_configuration() {
    log_info "Configuring recovery parameters..."
    
    # Get key pairs
    local key_pairs
    if key_pairs=$(aws ec2 describe-key-pairs \
        --region "$REGION" \
        --query 'KeyPairs[*].KeyName' \
        --output text 2>/dev/null) && [[ -n "$key_pairs" ]]; then
        
        echo "Available key pairs: $key_pairs"
        echo
        
        while [[ -z "$KEY_NAME" ]]; do
            read -p "Enter EC2 key pair name: " KEY_NAME
            
            if ! echo "$key_pairs" | grep -q "$KEY_NAME"; then
                log_warning "Key pair '$KEY_NAME' not found in this region"
                echo "Available: $key_pairs"
                KEY_NAME=""
            fi
        done
    else
        log_warning "Could not retrieve key pairs. You'll need to specify manually."
        read -p "Enter EC2 key pair name: " KEY_NAME
    fi
    
    # Get security groups
    echo
    read -p "Enter security group ID (sg-xxxxxxxxx): " SECURITY_GROUP
    while [[ ! "$SECURITY_GROUP" =~ ^sg-[0-9a-f]{8,17}$ ]]; do
        log_error "Invalid security group format"
        read -p "Enter security group ID (sg-xxxxxxxxx): " SECURITY_GROUP
    done
    
    # Get subnet
    echo
    read -p "Enter subnet ID (subnet-xxxxxxxxx): " SUBNET_ID
    while [[ ! "$SUBNET_ID" =~ ^subnet-[0-9a-f]{8,17}$ ]]; do
        log_error "Invalid subnet format"
        read -p "Enter subnet ID (subnet-xxxxxxxxx): " SUBNET_ID
    done
    
    # Instance type
    echo
    read -p "Enter instance type (default: $INSTANCE_TYPE): " instance_type_input
    if [[ -n "$instance_type_input" ]]; then
        INSTANCE_TYPE="$instance_type_input"
    fi
    
    log_success "Recovery configuration completed"
}

create_volume_from_snapshot() {
    local snapshot_id="$1"
    
    log_info "Creating EBS volume from snapshot: $snapshot_id"
    
    # Get the availability zone of the subnet
    local availability_zone
    if ! availability_zone=$(aws ec2 describe-subnets \
        --subnet-ids "$SUBNET_ID" \
        --region "$REGION" \
        --query 'Subnets[0].AvailabilityZone' \
        --output text 2>/dev/null); then
        log_error "Failed to determine availability zone for subnet: $SUBNET_ID"
        exit 1
    fi
    
    log_info "Target availability zone: $availability_zone"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create volume from snapshot $snapshot_id in AZ $availability_zone"
        echo "VOLUME_ID_PLACEHOLDER"
        return 0
    fi
    
    # Create volume from snapshot
    local volume_id
    if ! volume_id=$(aws ec2 create-volume \
        --snapshot-id "$snapshot_id" \
        --availability-zone "$availability_zone" \
        --region "$REGION" \
        --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=jenkins-recovery},{Key=Purpose,Value=Jenkins-Recovery}]' \
        --query 'VolumeId' \
        --output text 2>/dev/null); then
        log_error "Failed to create volume from snapshot"
        exit 1
    fi
    
    log_success "Volume created: $volume_id"
    
    # Wait for volume to be available
    log_info "Waiting for volume to become available..."
    if ! aws ec2 wait volume-available \
        --volume-ids "$volume_id" \
        --region "$REGION"; then
        log_error "Volume did not become available within timeout"
        exit 1
    fi
    
    log_success "Volume is ready: $volume_id"
    echo "$volume_id"
}

launch_recovery_instance() {
    local volume_id="$1"
    
    log_info "Launching recovery EC2 instance..."
    
    # Get the latest Amazon Linux 2 AMI
    local ami_id
    if ! ami_id=$(aws ec2 describe-images \
        --owners amazon \
        --region "$REGION" \
        --filters \
            "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
            "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text 2>/dev/null); then
        log_error "Failed to find suitable AMI"
        exit 1
    fi
    
    log_info "Using AMI: $ami_id"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would launch instance with:"
        echo "  AMI: $ami_id"
        echo "  Instance Type: $INSTANCE_TYPE"
        echo "  Key Name: $KEY_NAME"
        echo "  Security Group: $SECURITY_GROUP"
        echo "  Subnet: $SUBNET_ID"
        echo "INSTANCE_ID_PLACEHOLDER"
        return 0
    fi
    
    # Launch instance
    local instance_id
    if ! instance_id=$(aws ec2 run-instances \
        --image-id "$ami_id" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SECURITY_GROUP" \
        --subnet-id "$SUBNET_ID" \
        --region "$REGION" \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=jenkins-recovery},{Key=Purpose,Value=Jenkins-Recovery}]' \
        --query 'Instances[0].InstanceId' \
        --output text 2>/dev/null); then
        log_error "Failed to launch EC2 instance"
        exit 1
    fi
    
    log_success "Instance launched: $instance_id"
    
    # Wait for instance to be running
    log_info "Waiting for instance to be in running state..."
    if ! aws ec2 wait instance-running \
        --instance-ids "$instance_id" \
        --region "$REGION"; then
        log_error "Instance did not start within timeout"
        exit 1
    fi
    
    log_success "Instance is running: $instance_id"
    echo "$instance_id"
}

attach_volume_to_instance() {
    local volume_id="$1"
    local instance_id="$2"
    local device="/dev/sdf"  # Secondary device
    
    log_info "Attaching volume $volume_id to instance $instance_id"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would attach volume $volume_id to $instance_id at $device"
        return 0
    fi
    
    # Attach volume
    if ! aws ec2 attach-volume \
        --volume-id "$volume_id" \
        --instance-id "$instance_id" \
        --device "$device" \
        --region "$REGION" >/dev/null 2>&1; then
        log_error "Failed to attach volume to instance"
        exit 1
    fi
    
    # Wait for volume to be attached
    log_info "Waiting for volume attachment..."
    if ! aws ec2 wait volume-in-use \
        --volume-ids "$volume_id" \
        --region "$REGION"; then
        log_error "Volume attachment did not complete within timeout"
        exit 1
    fi
    
    log_success "Volume attached successfully"
}

show_recovery_instructions() {
    local instance_id="$1"
    local volume_id="$2"
    
    # Get instance details
    local instance_info
    if instance_info=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress,PublicDnsName]' \
        --output text 2>/dev/null); then
        
        local public_ip private_ip public_dns
        read -r public_ip private_ip public_dns <<< "$instance_info"
        
        echo
        log_success "Recovery instance ready!"
        echo
        echo "Instance Details:"
        echo "  Instance ID: $instance_id"
        echo "  Volume ID: $volume_id"
        echo "  Public IP: ${public_ip:-N/A}"
        echo "  Private IP: ${private_ip:-N/A}"
        echo "  Public DNS: ${public_dns:-N/A}"
        echo
        
        echo "Next Steps:"
        echo "1. Connect to the instance:"
        if [[ "$public_ip" != "None" && -n "$public_ip" ]]; then
            echo "   ssh -i ~/.ssh/$KEY_NAME.pem ec2-user@$public_ip"
        else
            echo "   ssh -i ~/.ssh/$KEY_NAME.pem ec2-user@$private_ip"
        fi
        echo
        echo "2. Mount the Jenkins data volume:"
        echo "   sudo mkdir -p /mnt/jenkins-recovery"
        echo "   sudo mount /dev/xvdf1 /mnt/jenkins-recovery"
        echo
        echo "3. Install Jenkins and restore data:"
        echo "   # Install Java and Jenkins"
        echo "   sudo yum update -y"
        echo "   sudo yum install -y java-1.8.0-openjdk"
        echo "   sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo"
        echo "   sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io.key"
        echo "   sudo yum install -y jenkins"
        echo
        echo "   # Stop Jenkins service"
        echo "   sudo systemctl stop jenkins"
        echo
        echo "   # Copy recovered data"
        echo "   sudo cp -r /mnt/jenkins-recovery/* /var/lib/jenkins/"
        echo "   sudo chown -R jenkins:jenkins /var/lib/jenkins"
        echo
        echo "   # Start Jenkins"
        echo "   sudo systemctl start jenkins"
        echo "   sudo systemctl enable jenkins"
        echo
        echo "4. Access Jenkins:"
        if [[ "$public_ip" != "None" && -n "$public_ip" ]]; then
            echo "   http://$public_ip:8080"
        else
            echo "   http://$private_ip:8080 (via VPN/bastion)"
        fi
        echo
        echo "5. Update DNS/load balancer to point to new instance"
        echo
        echo "6. Test all Jenkins functionality thoroughly"
    fi
}

#===============================================================================
# MAIN EXECUTION FLOW
#===============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                LIST_MODE=true
                shift
                ;;
            -i|--interactive)
                INTERACTIVE_MODE=true
                shift
                ;;
            -r|--region)
                REGION="$2"
                shift 2
                ;;
            --instance-type)
                INSTANCE_TYPE="$2"
                shift 2
                ;;
            --key-name)
                KEY_NAME="$2"
                shift 2
                ;;
            --security-group)
                SECURITY_GROUP="$2"
                shift 2
                ;;
            --subnet-id)
                SUBNET_ID="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$SNAPSHOT_ID" ]]; then
                    SNAPSHOT_ID="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"
    
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║              Jenkins Disaster Recovery                     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_prerequisites
    
    # Handle different modes
    if [[ "$LIST_MODE" == true ]]; then
        list_snapshots
        exit 0
    fi
    
    if [[ "$INTERACTIVE_MODE" == true ]]; then
        list_snapshots
        select_snapshot_interactive
        get_recovery_configuration
    else
        if [[ -z "$SNAPSHOT_ID" ]]; then
            log_error "Snapshot ID is required in non-interactive mode"
            echo "Use --interactive mode or provide snapshot ID as argument"
            exit 1
        fi
        
        # Validate required parameters for direct mode
        if [[ -z "$KEY_NAME" || -z "$SECURITY_GROUP" || -z "$SUBNET_ID" ]]; then
            log_error "Key name, security group, and subnet ID are required"
            echo "Use --interactive mode or provide all required parameters"
            exit 1
        fi
    fi
    
    # Validate snapshot
    validate_snapshot "$SNAPSHOT_ID"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_warning "DRY RUN MODE - No resources will be created"
        echo
    fi
    
    # Show configuration summary
    echo
    log_info "Recovery Configuration Summary:"
    echo "  Snapshot ID: $SNAPSHOT_ID"
    echo "  Region: $REGION"
    echo "  Instance Type: $INSTANCE_TYPE"
    echo "  Key Name: $KEY_NAME"
    echo "  Security Group: $SECURITY_GROUP"
    echo "  Subnet ID: $SUBNET_ID"
    echo
    
    if [[ "$DRY_RUN" != true ]]; then
        read -p "Proceed with recovery? (y/N): " -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Recovery cancelled"
            exit 0
        fi
    fi
    
    # Execute recovery process
    echo
    log_info "Starting recovery process..."
    
    local volume_id
    volume_id=$(create_volume_from_snapshot "$SNAPSHOT_ID")
    
    local instance_id
    instance_id=$(launch_recovery_instance "$volume_id")
    
    if [[ "$DRY_RUN" != true ]]; then
        attach_volume_to_instance "$volume_id" "$instance_id"
        show_recovery_instructions "$instance_id" "$volume_id"
    else
        log_info "[DRY RUN] Recovery process simulation completed"
        echo "Resources that would be created:"
        echo "  • EBS Volume from snapshot $SNAPSHOT_ID"
        echo "  • EC2 Instance ($INSTANCE_TYPE)"
        echo "  • Volume attachment"
    fi
    
    log_success "Recovery process completed!"
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi