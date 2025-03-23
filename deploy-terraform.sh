#!/bin/bash
# deploy-terraform.sh - Script to deploy Terraform infrastructure generated from SCORE
# Usage: ./deploy-terraform.sh [--auto-approve] [--destroy]

set -e

# Colors for output formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Script variables
TERRAFORM_DIR="terraform"
AUTO_APPROVE=""
DESTROY=false
WORKSPACE=""

# Function to print colored messages
print_section() {
  echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}"
}

print_info() {
  echo -e "${YELLOW}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --auto-approve)
      AUTO_APPROVE="-auto-approve"
      shift
      ;;
    --destroy)
      DESTROY=true
      shift
      ;;
    --workspace)
      WORKSPACE="$2"
      shift
      shift
      ;;
    --help)
      echo "Usage: $0 [--auto-approve] [--destroy] [--workspace name]"
      echo "  --auto-approve: Skip confirmation prompts"
      echo "  --destroy: Destroy the infrastructure instead of creating it"
      echo "  --workspace name: Use specified Terraform workspace"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Check if terraform directory exists
if [ ! -d "$TERRAFORM_DIR" ]; then
  print_error "Terraform directory not found. Please run the SCORE parser first."
fi

# Check terraform installation
if ! command -v terraform &> /dev/null; then
  print_error "Terraform is not installed. Please install Terraform and try again."
fi

# Navigate to terraform directory
cd "$TERRAFORM_DIR"

# Start deployment process
print_section "Terraform Deployment Process"
print_info "Starting deployment from SCORE-generated Terraform configuration"

# Initialize Terraform
print_section "Initializing Terraform"
terraform init -upgrade

# Select workspace if specified
if [ -n "$WORKSPACE" ]; then
  print_info "Selecting workspace: $WORKSPACE"
  terraform workspace select "$WORKSPACE" 2>/dev/null || terraform workspace new "$WORKSPACE"
fi

# Show current workspace
CURRENT_WORKSPACE=$(terraform workspace show)
print_info "Current workspace: $CURRENT_WORKSPACE"

# Validate the configuration
print_section "Validating Terraform Configuration"
terraform validate

# Check for environment variables in SCORE configuration
print_info "Checking for required environment variables"
REQUIRED_VARS=$(grep -r "\${.*}" --include="*.tf" . | grep -v "\${var\." | grep -v "\${local\." | grep -oP '\$\{\K[^}]+' | sort | uniq)

if [ -n "$REQUIRED_VARS" ]; then
  print_info "The following environment variables may be required:"
  for VAR in $REQUIRED_VARS; do
    echo "  - $VAR"
    if [ -z "${!VAR}" ]; then
      echo "    (not set)"
    else
      echo "    (set)"
    fi
  done
fi

# If we're destroying, handle that separately
if [ "$DESTROY" = true ]; then
  print_section "Destroying Infrastructure"
  
  # First, check for ECS services that might prevent cluster deletion
  print_info "Checking for ECS services that might block cluster deletion..."
  
  # Find ECS clusters in the Terraform state
  ECS_CLUSTERS=$(terraform state list | grep aws_ecs_cluster || echo "")
  
  if [ -n "$ECS_CLUSTERS" ]; then
    # For each cluster, get its name and check for services
    for CLUSTER in $ECS_CLUSTERS; do
      CLUSTER_NAME=$(terraform state show $CLUSTER | grep name | head -1 | sed 's/.*= "\(.*\)".*/\1/')
      
      if [ -n "$CLUSTER_NAME" ]; then
        print_info "Found ECS cluster: $CLUSTER_NAME"
        
        # Check for active services in the cluster
        AWS_SERVICES=$(aws ecs list-services --cluster $CLUSTER_NAME --output text 2>/dev/null | grep "SERVICE_ARN" || echo "")
        
        if [ -n "$AWS_SERVICES" ]; then
          print_info "Cluster has active services. Will attempt to remove them first."
          
          # Get service names from ARNs
          for SERVICE_ARN in $AWS_SERVICES; do
            SERVICE_NAME=$(echo $SERVICE_ARN | awk -F/ '{print $2}')
            
            print_info "Scaling down service: $SERVICE_NAME"
            # Scale service down to 0
            aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0 --output text >/dev/null 2>&1
            
            print_info "Waiting for service tasks to terminate..."
            # Wait for tasks to terminate
            aws ecs wait services-inactive --cluster $CLUSTER_NAME --services $SERVICE_NAME >/dev/null 2>&1
            
            if [ -z "$AUTO_APPROVE" ]; then
              read -p "Attempt to delete service $SERVICE_NAME manually? (y/N) " -n 1 -r
              echo
              if [[ $REPLY =~ ^[Yy]$ ]]; then
                print_info "Deleting service: $SERVICE_NAME"
                aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force >/dev/null 2>&1
              fi
            else
              print_info "Auto-deleting service: $SERVICE_NAME"
              aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force >/dev/null 2>&1
            fi
          done
        fi
      fi
    done
  fi
  
  # Create a destroy plan
  print_info "Creating destroy plan..."
  terraform plan -destroy -out=destroy.tfplan
  
  if [ -z "$AUTO_APPROVE" ]; then
    echo -e "${RED}WARNING: This will destroy all resources in workspace: $CURRENT_WORKSPACE${NC}"
    echo -e "${RED}The following resources will be destroyed:${NC}"
    terraform show destroy.tfplan | grep -E '^\s*[-~+#] ' | grep '# ' | sed 's/# /  - /'
    
    echo
    read -p "Are you sure you want to continue with destruction? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      print_info "Destruction cancelled"
      exit 0
    fi
  fi
  
  print_info "Executing destroy plan..."
  if [ -z "$AUTO_APPROVE" ]; then
    terraform apply destroy.tfplan
  else
    terraform apply -auto-approve destroy.tfplan
  fi
  
  DESTROY_EXIT_CODE=$?
  if [ $DESTROY_EXIT_CODE -eq 0 ]; then
    print_success "Infrastructure successfully destroyed"
    
    # Clean up plan files
    rm -f destroy.tfplan tfplan
    
    # Check if we should remove the terraform state files too
    if [ -z "$AUTO_APPROVE" ]; then
      read -p "Do you want to remove Terraform state files as well? (y/N) " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf .terraform terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl
        print_info "Terraform state files removed"
      fi
    fi
  else
    print_error "Failed to destroy infrastructure (Exit code: $DESTROY_EXIT_CODE)"
    
    # Check for common error patterns and provide specific advice
    TERRAFORM_ERRORS=$(terraform destroy -auto-approve 2>&1 || true)
    
    if echo "$TERRAFORM_ERRORS" | grep -q "ClusterContainsServicesException"; then
      print_info "ECS Cluster deletion failed due to active services. Try these steps:"
      echo "  1. Manually scale down all services in the ECS cluster to 0 tasks"
      echo "     aws ecs list-services --cluster <cluster-name>"
      echo "     aws ecs update-service --cluster <cluster-name> --service <service-name> --desired-count 0"
      echo "  2. Wait for tasks to terminate"
      echo "     aws ecs wait services-inactive --cluster <cluster-name> --services <service-name>"
      echo "  3. Delete each service manually"
      echo "     aws ecs delete-service --cluster <cluster-name> --service <service-name> --force"
      echo "  4. Run destroy again"
      echo "     ./deploy-terraform.sh --destroy"
    elif echo "$TERRAFORM_ERRORS" | grep -q "DBInstanceNotFound"; then
      print_info "RDS instance not found. The database may have been deleted outside of Terraform."
      echo "  Try: terraform state rm <resource_address>"
    else
      print_info "General troubleshooting tips:"
      echo "  - Check for resources that might be protected from deletion"
      echo "  - Verify IAM permissions for resource deletion"
      echo "  - Some resources might need manual cleanup in the AWS Console"
      echo "  - Try running with --auto-approve to skip confirmations"
    fi
  fi
  
  exit $DESTROY_EXIT_CODE
fi

# Create a plan
print_section "Creating Terraform Plan"
terraform plan -out=tfplan

# Apply the plan
print_section "Applying Configuration"

if [ -z "$AUTO_APPROVE" ]; then
  echo -e "${YELLOW}Terraform will perform the actions described above.${NC}"
  read -p "Do you want to perform these actions? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Deployment cancelled"
    exit 0
  fi
  terraform apply tfplan
else
  terraform apply $AUTO_APPROVE tfplan
fi

# Verify successful application
if [ $? -eq 0 ]; then
  print_success "Terraform deployment completed successfully!"
  
  # Output important information
  print_section "Deployment Outputs"
  terraform output
  
  # Save outputs to a file
  terraform output -json > "../terraform_outputs.json"
  print_info "Outputs saved to terraform_outputs.json"

  print_section "Next Steps"
  echo "1. Review the outputs above for access information to your resources"
  echo "2. To update your deployment, modify your SCORE file and re-run the parser"
  echo "3. To destroy this infrastructure, run: ./deploy-terraform.sh --destroy"
else
  print_error "Terraform deployment failed"
fi