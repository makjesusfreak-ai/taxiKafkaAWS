#!/bin/bash
set -e

# Configuration
CLUSTER_NAME="taxi-kafka-msk"
REGION="${AWS_REGION:-us-east-1}"
MSK_STACK_NAME="${CLUSTER_NAME}-infrastructure"
SAM_STACK_NAME="${CLUSTER_NAME}-lambda-appsync"
CLOUDFORMATION_DIR="$(dirname "$0")/cloudformation"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_stack_exists() {
    local stack_name=$1
    aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null
}

wait_for_stack() {
    local stack_name=$1
    local action=$2
    log_info "Waiting for $stack_name to $action (this may take 15-30 minutes for MSK)..."
    aws cloudformation wait "stack-${action}-complete" --stack-name "$stack_name" --region "$REGION"
    log_info "$stack_name $action complete!"
}

deploy_up() {
    log_info "Deploying infrastructure to region: $REGION"

    # Step 1: Deploy MSK infrastructure
    log_info "Step 1/2: Deploying MSK infrastructure stack..."

    if check_stack_exists "$MSK_STACK_NAME"; then
        log_warn "Stack $MSK_STACK_NAME already exists, updating..."
        aws cloudformation update-stack \
            --stack-name "$MSK_STACK_NAME" \
            --template-body "file://${CLOUDFORMATION_DIR}/msk-infrastructure.yaml" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION" 2>/dev/null || log_info "No updates needed for $MSK_STACK_NAME"
    else
        aws cloudformation create-stack \
            --stack-name "$MSK_STACK_NAME" \
            --template-body "file://${CLOUDFORMATION_DIR}/msk-infrastructure.yaml" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION"
        wait_for_stack "$MSK_STACK_NAME" "create"
    fi

    # Get outputs from MSK stack
    log_info "Getting outputs from MSK infrastructure stack..."

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

    log_info "MSK Cluster ARN: $MSK_CLUSTER_ARN"
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
    log_info "To view AppSync endpoints, run:"
    echo "  aws cloudformation describe-stacks --stack-name $SAM_STACK_NAME --query 'Stacks[0].Outputs' --output table"
}

deploy_down() {
    log_info "Tearing down infrastructure in region: $REGION"

    # Step 1: Delete SAM stack first (depends on MSK)
    if check_stack_exists "$SAM_STACK_NAME"; then
        log_info "Step 1/2: Deleting SAM Lambda/AppSync stack..."
        aws cloudformation delete-stack --stack-name "$SAM_STACK_NAME" --region "$REGION"
        wait_for_stack "$SAM_STACK_NAME" "delete"
    else
        log_info "SAM stack $SAM_STACK_NAME does not exist, skipping..."
    fi

    # Step 2: Delete MSK infrastructure stack
    if check_stack_exists "$MSK_STACK_NAME"; then
        log_info "Step 2/2: Deleting MSK infrastructure stack..."
        log_warn "Note: S3 bucket will be retained (DeletionPolicy: Retain)"
        aws cloudformation delete-stack --stack-name "$MSK_STACK_NAME" --region "$REGION"
        wait_for_stack "$MSK_STACK_NAME" "delete"
    else
        log_info "MSK stack $MSK_STACK_NAME does not exist, skipping..."
    fi

    log_info "Teardown complete!"
    log_info "S3 bucket taxi-kafka-msk-logs-* was retained and still exists."
}

status() {
    log_info "Checking stack status in region: $REGION"
    echo ""

    for stack in "$MSK_STACK_NAME" "$SAM_STACK_NAME"; do
        if check_stack_exists "$stack"; then
            STATUS=$(aws cloudformation describe-stacks --stack-name "$stack" \
                --query "Stacks[0].StackStatus" --output text --region "$REGION")
            echo -e "  $stack: ${GREEN}$STATUS${NC}"
        else
            echo -e "  $stack: ${YELLOW}NOT DEPLOYED${NC}"
        fi
    done
    echo ""
}

usage() {
    echo ""
    echo "MSK Provisioned Deploy Script"
    echo "=============================="
    echo ""
    echo "Usage: $0 {up|down|status}"
    echo ""
    echo "Commands:"
    echo "  up      Deploy all infrastructure (MSK Provisioned + Lambda/AppSync)"
    echo "  down    Tear down all infrastructure (retains S3 bucket)"
    echo "  status  Check deployment status"
    echo ""
    echo "Environment variables:"
    echo "  AWS_REGION  AWS region (default: us-east-1)"
    echo ""
    echo "WARNING: MSK Provisioned costs ~\$500/month even when idle!"
    echo "Consider using ./deploy-serverless.sh for dev/test (zero idle cost)"
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
