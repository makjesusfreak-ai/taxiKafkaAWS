#!/bin/bash
set -e

# Configuration
CLUSTER_NAME="taxi-kafka-msk"
REGION="${AWS_REGION:-us-east-1}"
MSK_STACK_NAME="${CLUSTER_NAME}-serverless-infrastructure"
SAM_STACK_NAME="${CLUSTER_NAME}-lambda-appsync"
CLOUDFORMATION_DIR="$(dirname "$0")/cloudformation"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_cost() { echo -e "${CYAN}[COST]${NC} $1"; }

check_stack_exists() {
    local stack_name=$1
    aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null
}

get_stack_status() {
    local stack_name=$1
    aws cloudformation describe-stacks --stack-name "$stack_name" \
        --query "Stacks[0].StackStatus" --output text --region "$REGION" 2>/dev/null || echo "NOT_FOUND"
}

wait_for_stack() {
    local stack_name=$1
    local action=$2
    log_info "Waiting for $stack_name to $action..."
    aws cloudformation wait "stack-${action}-complete" --stack-name "$stack_name" --region "$REGION"
    log_info "$stack_name $action complete!"
}

cleanup_lambda_enis() {
    log_info "Checking for orphaned Lambda ENIs..."

    local vpc_id=$1
    local enis=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=description,Values=AWS Lambda VPC ENI*" \
        --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' \
        --output text --region "$REGION")

    if [ -n "$enis" ]; then
        for eni in $enis; do
            log_info "Deleting orphaned ENI: $eni"
            aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" || true
        done
    fi

    # Also check for event source mappings
    local mappings=$(aws lambda list-event-source-mappings \
        --query "EventSourceMappings[?contains(EventSourceArn, 'kafka')].[UUID]" \
        --output text --region "$REGION")

    if [ -n "$mappings" ]; then
        for uuid in $mappings; do
            log_info "Deleting orphaned event source mapping: $uuid"
            aws lambda delete-event-source-mapping --uuid "$uuid" --region "$REGION" || true
        done
        sleep 30  # Wait for ENIs to be released
    fi
}

deploy_up() {
    log_info "Deploying MSK Serverless infrastructure to region: $REGION"
    log_cost "MSK Serverless: \$0 idle cost, pay only for data throughput"
    log_cost "  - Ingress: \$0.10/GB"
    log_cost "  - Egress: \$0.05/GB"
    log_cost "  - Storage: \$0.10/GB/month"
    echo ""

    # Step 1: Deploy MSK Serverless infrastructure
    log_info "Step 1/2: Deploying MSK Serverless infrastructure stack..."

    if check_stack_exists "$MSK_STACK_NAME"; then
        local status=$(get_stack_status "$MSK_STACK_NAME")
        if [ "$status" == "CREATE_COMPLETE" ] || [ "$status" == "UPDATE_COMPLETE" ]; then
            log_warn "Stack $MSK_STACK_NAME already exists ($status), updating..."
            aws cloudformation update-stack \
                --stack-name "$MSK_STACK_NAME" \
                --template-body "file://${CLOUDFORMATION_DIR}/msk-serverless-infrastructure.yaml" \
                --capabilities CAPABILITY_NAMED_IAM \
                --region "$REGION" 2>/dev/null && wait_for_stack "$MSK_STACK_NAME" "update" || log_info "No updates needed"
        else
            log_error "Stack $MSK_STACK_NAME is in state: $status. Please resolve manually."
            exit 1
        fi
    else
        aws cloudformation create-stack \
            --stack-name "$MSK_STACK_NAME" \
            --template-body "file://${CLOUDFORMATION_DIR}/msk-serverless-infrastructure.yaml" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION"
        wait_for_stack "$MSK_STACK_NAME" "create"
    fi

    # Get outputs from MSK stack
    log_info "Getting outputs from MSK Serverless infrastructure stack..."

    MSK_CLUSTER_ARN=$(aws cloudformation describe-stacks \
        --stack-name "$MSK_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='MSKClusterArn'].OutputValue" \
        --output text --region "$REGION")

    VPC_ID=$(aws cloudformation describe-stacks \
        --stack-name "$MSK_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='VPCId'].OutputValue" \
        --output text --region "$REGION")

    SUBNET_IDS=$(aws cloudformation describe-stacks \
        --stack-name "$MSK_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='SubnetIds'].OutputValue" \
        --output text --region "$REGION")

    MSK_SG_ID=$(aws cloudformation describe-stacks \
        --stack-name "$MSK_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='MSKSecurityGroupId'].OutputValue" \
        --output text --region "$REGION")

    GLUE_REGISTRY_ARN=$(aws cloudformation describe-stacks \
        --stack-name "$MSK_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='GlueRegistryArn'].OutputValue" \
        --output text --region "$REGION")

    log_info "MSK Serverless Cluster ARN: $MSK_CLUSTER_ARN"
    log_info "VPC ID: $VPC_ID"

    # Step 2: Deploy SAM stack
    log_info "Step 2/2: Deploying SAM Lambda/AppSync stack..."

    cd "$CLOUDFORMATION_DIR"
    sam build
    sam deploy \
        --stack-name "$SAM_STACK_NAME" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --parameter-overrides \
            "MSKClusterArn=$MSK_CLUSTER_ARN" \
            "VPCId=$VPC_ID" \
            "SubnetIds=$SUBNET_IDS" \
            "MSKSecurityGroupId=$MSK_SG_ID" \
            "GlueRegistryArn=$GLUE_REGISTRY_ARN" \
        --no-confirm-changeset \
        --no-fail-on-empty-changeset

    log_info "Deployment complete!"
    echo ""
    log_cost "Your MSK Serverless cluster is now running with zero idle costs!"
    echo ""
    log_info "To view AppSync endpoints, run:"
    echo "  aws cloudformation describe-stacks --stack-name $SAM_STACK_NAME --query 'Stacks[0].Outputs' --output table"
}

deploy_down() {
    log_info "Tearing down MSK Serverless infrastructure in region: $REGION"

    # Step 1: Delete SAM stack first (depends on MSK)
    if check_stack_exists "$SAM_STACK_NAME"; then
        log_info "Step 1/2: Deleting SAM Lambda/AppSync stack..."
        aws cloudformation delete-stack --stack-name "$SAM_STACK_NAME" --region "$REGION"
        wait_for_stack "$SAM_STACK_NAME" "delete"
    else
        log_info "SAM stack $SAM_STACK_NAME does not exist, skipping..."
    fi

    # Step 2: Delete MSK Serverless infrastructure stack
    if check_stack_exists "$MSK_STACK_NAME"; then
        # Get VPC ID before deletion for cleanup
        VPC_ID=$(aws cloudformation describe-stacks \
            --stack-name "$MSK_STACK_NAME" \
            --query "Stacks[0].Outputs[?OutputKey=='VPCId'].OutputValue" \
            --output text --region "$REGION" 2>/dev/null || echo "")

        log_info "Step 2/2: Deleting MSK Serverless infrastructure stack..."
        aws cloudformation delete-stack --stack-name "$MSK_STACK_NAME" --region "$REGION"

        # Wait and check for failures
        if ! aws cloudformation wait stack-delete-complete --stack-name "$MSK_STACK_NAME" --region "$REGION" 2>/dev/null; then
            log_warn "Stack deletion may have failed, checking for orphaned resources..."

            if [ -n "$VPC_ID" ]; then
                cleanup_lambda_enis "$VPC_ID"

                # Retry deletion
                log_info "Retrying stack deletion..."
                aws cloudformation delete-stack --stack-name "$MSK_STACK_NAME" --region "$REGION"
                wait_for_stack "$MSK_STACK_NAME" "delete"
            fi
        fi
    else
        log_info "MSK stack $MSK_STACK_NAME does not exist, skipping..."
    fi

    log_info "Teardown complete!"
}

status() {
    log_info "Checking stack status in region: $REGION"
    echo ""

    for stack in "$MSK_STACK_NAME" "$SAM_STACK_NAME"; do
        if check_stack_exists "$stack"; then
            STATUS=$(get_stack_status "$stack")
            echo -e "  $stack: ${GREEN}$STATUS${NC}"
        else
            echo -e "  $stack: ${YELLOW}NOT DEPLOYED${NC}"
        fi
    done
    echo ""

    # Check for provisioned stack too
    PROVISIONED_STACK="${CLUSTER_NAME}-infrastructure"
    if check_stack_exists "$PROVISIONED_STACK"; then
        STATUS=$(get_stack_status "$PROVISIONED_STACK")
        log_warn "Provisioned MSK stack also exists: $PROVISIONED_STACK ($STATUS)"
        log_warn "Consider deleting it to avoid costs: ./deploy.sh down"
    fi
}

usage() {
    echo ""
    echo "MSK Serverless Deploy Script"
    echo "============================="
    echo ""
    echo "Usage: $0 {up|down|status}"
    echo ""
    echo "Commands:"
    echo "  up      Deploy MSK Serverless + Lambda/AppSync (zero idle cost)"
    echo "  down    Tear down all infrastructure"
    echo "  status  Check deployment status"
    echo ""
    echo "Environment variables:"
    echo "  AWS_REGION  AWS region (default: us-east-1)"
    echo ""
    echo "Cost comparison:"
    echo "  Provisioned (./deploy.sh):    ~\$500/month idle"
    echo "  Serverless (./deploy-serverless.sh): \$0 idle, pay per GB"
    echo ""
}

case "${1:-}" in
    up)
        deploy_up
        ;;
    down)
        deploy_down
        ;;
    status)
        status
        ;;
    *)
        usage
        exit 1
        ;;
esac
