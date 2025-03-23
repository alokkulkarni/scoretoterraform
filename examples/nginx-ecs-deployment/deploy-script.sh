#!/bin/bash
# SCORE to Terraform Deployment Script

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Script variables
SCORE_FILE="score.yaml"
TERRAFORM_DIR="terraform"
PARSER_SCRIPT="score-parser.js"

# Function to print colored messages
print_step() {
  echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_info() {
  echo -e "${YELLOW}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Check if score.yaml exists
if [ ! -f "$SCORE_FILE" ]; then
  print_error "SCORE file not found: $SCORE_FILE"
  exit 1
fi

print_step "SCORE to Terraform Deployment"
print_info "Using SCORE file: $SCORE_FILE"

# Check dependencies
print_info "Checking dependencies..."
command -v node >/dev/null 2>&1 || { print_error "Node.js is required but not installed. Aborting."; exit 1; }
command -v npm >/dev/null 2>&1 || { print_error "npm is required but not installed. Aborting."; exit 1; }
command -v terraform >/dev/null 2>&1 || { print_error "Terraform is required but not installed. Aborting."; exit 1; }

# Install required npm packages if not already present
if [ ! -f "package.json" ]; then
  print_info "Initializing npm project..."
  npm init -y >/dev/null 2>&1
fi

print_info "Installing required dependencies..."
npm install --quiet js-yaml >/dev/null 2>&1

# Create the parser script
print_info "Creating SCORE parser script..."
cat > "$PARSER_SCRIPT" <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const yaml = require('js-yaml');
const path = require('path');

// Configuration
const SCORE_FILE = 'score.yaml';
const TERRAFORM_DIR = 'terraform';

// Parse SCORE YAML file
try {
  console.log(`Parsing SCORE file: ${SCORE_FILE}`);
  const scoreContent = fs.readFileSync(SCORE_FILE, 'utf8');
  const score = yaml.load(scoreContent);
  
  // Create Terraform directory if it doesn't exist
  if (!fs.existsSync(TERRAFORM_DIR)) {
    fs.mkdirSync(TERRAFORM_DIR, { recursive: true });
  }
  
  // Extract metadata
  const metadata = score.metadata || {};
  const provider = metadata.provider || 'aws';
  const region = metadata.region || 'us-west-2';
  const environment = metadata.environment || 'dev';
  const projectName = metadata.name || 'score-app';
  const tags = metadata.tags || {};
  
  // Extract workloads
  const workloads = score.workloads || {};
  
  // Create provider.tf
  const providerTf = `
# Generated from SCORE file
provider "${provider}" {
  region = "${region}"
}

terraform {
  required_providers {
    ${provider} = {
      source  = "hashicorp/${provider}"
      version = "~> 5.79.0"
    }
  }
}
`;
  fs.writeFileSync(path.join(TERRAFORM_DIR, 'provider.tf'), providerTf);
  
  // Create variables.tf
  const variablesTf = `
# Variables generated from SCORE file
variable "environment" {
  description = "Deployment environment"
  default     = "${environment}"
}

variable "project_name" {
  description = "Project name"
  default     = "${projectName}"
}

variable "region" {
  description = "Deployment region"
  default     = "${region}"
}

locals {
  common_tags = ${JSON.stringify(tags, null, 2)}
}
`;
  fs.writeFileSync(path.join(TERRAFORM_DIR, 'variables.tf'), variablesTf);
  
  // Create main.tf with modules for each workload
  let mainTf = `
# Main Terraform configuration generated from SCORE file
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  
  name = "\${var.project_name}-\${var.environment}"
  cidr = "${score.resources?.networking?.cidr || "10.0.0.0/16"}"
  
  azs             = ["\${var.region}a", "\${var.region}b", "\${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  
  enable_nat_gateway = true
  single_nat_gateway = true
  
  tags = local.common_tags
}

`;
  
  // Process each workload
  Object.keys(workloads).forEach(workloadName => {
    const workload = workloads[workloadName];
    const workloadType = workload.type || 'container';
    
    mainTf += `
# Workload: ${workloadName} (${workloadType})
module "${workloadName}" {
  source = "./modules/${workloadType}"
  
  name        = "${workloadName}"
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
  subnets     = module.vpc.private_subnets
  public_subnets = module.vpc.public_subnets
`;
    
    // Add workload-specific variables
    switch (workloadType) {
      case 'container':
        mainTf += `  image       = "${workload.image}"
  cpu         = ${workload.resources?.cpu || 256}
  memory      = ${workload.resources?.memory || 512}
  port        = ${workload.ports?.[0]?.port || 80}
  replicas    = ${workload.replicas || 1}
  environment_variables = ${JSON.stringify(workload.environment || {}, null, 2)}
`;
        break;
      
      case 'function':
        mainTf += `  runtime     = "${workload.runtime}"
  handler     = "${workload.handler}"
  memory      = ${workload.resources?.memory || 128}
  environment_variables = ${JSON.stringify(workload.environment || {}, null, 2)}
`;
        break;
      
      case 'database':
        mainTf += `  engine      = "${workload.engine}"
  version     = "${workload.version}"
  instance    = "${workload.resources?.instance || "db.t3.micro"}"
  storage     = ${workload.resources?.storage || 20}
  backup_retention = ${workload.backup?.retention || 7}
`;
        break;
    }
    
    mainTf += `  tags        = local.common_tags
}

`;
  });
  
  mainTf += `
# Outputs
output "vpc_id" {
  value = module.vpc.vpc_id
}
`;

  // Add outputs for each workload
  Object.keys(workloads).forEach(workloadName => {
    mainTf += `
output "${workloadName}_details" {
  value = module.${workloadName}
}
`;
  });
  
  fs.writeFileSync(path.join(TERRAFORM_DIR, 'main.tf'), mainTf);
  
  // Create module directories and templates
  const modulesDir = path.join(TERRAFORM_DIR, 'modules');
  if (!fs.existsSync(modulesDir)) {
    fs.mkdirSync(modulesDir, { recursive: true });
  }
  
  // Create module templates for each workload type
  const workloadTypes = new Set();
  Object.values(workloads).forEach(workload => {
    workloadTypes.add(workload.type || 'container');
  });
  
  // Create module templates
  workloadTypes.forEach(type => {
    const moduleDir = path.join(modulesDir, type);
    if (!fs.existsSync(moduleDir)) {
      fs.mkdirSync(moduleDir, { recursive: true });
    }
    
    let moduleTf = '';
    let variablesTf = '';
    let outputsTf = '';
    
    switch (type) {
      case 'container':
        variablesTf = `
# Variables for container module
variable "name" {
  description = "The name of the container service"
  type        = string
}

variable "environment" {
  description = "The deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID"
  type        = string
}

variable "subnets" {
  description = "The subnet IDs to deploy to"
  type        = list(string)
}

variable "public_subnets" {
  description = "The public subnet IDs for the load balancer"
  type        = list(string)
}

variable "image" {
  description = "The container image to deploy"
  type        = string
}

variable "cpu" {
  description = "The number of CPU units to allocate"
  type        = number
  default     = 256
}

variable "memory" {
  description = "The amount of memory to allocate"
  type        = number
  default     = 512
}

variable "port" {
  description = "The container port"
  type        = number
  default     = 80
}

variable "replicas" {
  description = "The number of container replicas"
  type        = number
  default     = 1
}

variable "environment_variables" {
  description = "Environment variables for the container"
  type        = map(string)
  default     = {}
}

variable "health_check_path" {
  description = "Path for health checks"
  type        = string
  default     = "/"
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
`;

        moduleTf = `
# Container deployment module
resource "aws_ecs_cluster" "this" {
  name = "\${var.name}-\${var.environment}"
  
  tags = var.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = "\${var.name}-\${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  
  container_definitions = jsonencode([
    {
      name         = var.name
      image        = var.image
      essential    = true
      portMappings = [
        {
          containerPort = var.port
          hostPort      = var.port
        }
      ]
      environment  = [
        for key, value in var.environment : {
          name  = key
          value = value
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/\${var.name}-\${var.environment}"
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:\${var.port}\${var.health_check_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])
  
  tags = var.tags
}

resource "aws_ecs_service" "this" {
  name            = "\${var.name}-\${var.environment}"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.replicas
  launch_type     = "FARGATE"
  
  network_configuration {
    subnets          = var.subnets
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = true
  }
  
  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.name
    container_port   = var.port
  }
  
  depends_on = [
    aws_lb_listener.this,
    aws_iam_role_policy_attachment.ecs_execution,
    aws_iam_role_policy_attachment.docker_hub_pull
  ]
  
  tags = var.tags
}

# Application Load Balancer
resource "aws_lb" "this" {
  name               = "\${var.name}-\${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnets
  
  enable_deletion_protection = false
  
  tags = var.tags
}

# Target group for the ALB
resource "aws_lb_target_group" "this" {
  name        = "\${var.name}-\${var.environment}-tg"
  port        = var.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  
  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-299"
  }
  
  tags = var.tags
}

# ALB listener
resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
  
  tags = var.tags
}

# Security group for the ECS tasks
resource "aws_security_group" "this" {
  name        = "\${var.name}-\${var.environment}-ecs"
  description = "Security group for \${var.name} container"
  vpc_id      = var.vpc_id
  
  ingress {
    from_port       = var.port
    to_port         = var.port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = var.tags
}

# Security group for the ALB
resource "aws_security_group" "alb" {
  name        = "\${var.name}-\${var.environment}-alb"
  description = "Security group for \${var.name} load balancer"
  vpc_id      = var.vpc_id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = var.tags
}

# IAM role for ECS task execution (pulling images, etc.)
resource "aws_iam_role" "ecs_execution" {
  name = "\${var.name}-\${var.environment}-ecs-execution"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

# IAM role for ECS task (application permissions)
resource "aws_iam_role" "ecs_task" {
  name = "\${var.name}-\${var.environment}-ecs-task"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

# Attach the AWS managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Custom policy for Docker Hub image pulling
resource "aws_iam_policy" "docker_hub_pull" {
  name        = "\${var.name}-\${var.environment}-docker-hub-pull"
  description = "Policy to allow pulling images from Docker Hub"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
  
  tags = var.tags
}

# Attach the Docker Hub policy to the execution role
resource "aws_iam_role_policy_attachment" "docker_hub_pull" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = aws_iam_policy.docker_hub_pull.arn
}

# Create CloudWatch log group for container logs
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/\${var.name}-\${var.environment}"
  retention_in_days = 30
  
  tags = var.tags
}

data "aws_region" "current" {}
`;

        outputsTf = `
# Outputs for container module
output "cluster_id" {
  description = "The ECS cluster ID"
  value       = aws_ecs_cluster.this.id
}

output "service_id" {
  description = "The ECS service ID"
  value       = aws_ecs_service.this.id
}

output "load_balancer_dns" {
  description = "The DNS name of the load balancer"
  value       = aws_lb.this.dns_name
}

output "load_balancer_url" {
  description = "The URL to access the application"
  value       = "http://\${aws_lb.this.dns_name}"
}

output "load_balancer_arn" {
  description = "The ARN of the load balancer"
  value       = aws_lb.this.arn
}

output "security_group_id" {
  description = "The security group ID for ECS tasks"
  value       = aws_security_group.this.id
}

output "alb_security_group_id" {
  description = "The security group ID for the ALB"
  value       = aws_security_group.alb.id
}

output "task_execution_role_arn" {
  description = "The task execution role ARN"
  value       = aws_iam_role.ecs_execution.arn
}

output "task_role_arn" {
  description = "The task role ARN"
  value       = aws_iam_role.ecs_task.arn
}
`;
        break;
      
      case 'function':
        variablesTf = `
# Variables for function module
variable "name" {
  description = "The name of the function"
  type        = string
}

variable "environment" {
  description = "The deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID"
  type        = string
}

variable "subnets" {
  description = "The subnet IDs to deploy to"
  type        = list(string)
}

variable "runtime" {
  description = "The function runtime"
  type        = string
  default     = "nodejs16.x"
}

variable "handler" {
  description = "The function handler"
  type        = string
  default     = "index.handler"
}

variable "memory" {
  description = "The amount of memory to allocate"
  type        = number
  default     = 128
}

variable "environment_variables" {
  description = "Environment variables for the function"
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
`;

        moduleTf = `
# Function deployment module
resource "aws_lambda_function" "this" {
  function_name = "\${var.name}-\${var.environment}"
  role          = aws_iam_role.lambda_execution.arn
  runtime       = var.runtime
  handler       = var.handler
  memory_size   = var.memory
  timeout       = 30
  
  # This is a placeholder - in a real implementation you would
  # need to properly package and deploy your function code
  filename      = "function.zip"
  
  vpc_config {
    subnet_ids         = var.subnets
    security_group_ids = [aws_security_group.this.id]
  }
  
  environment {
    variables = var.environment
  }
  
  tags = var.tags
}

resource "aws_security_group" "this" {
  name        = "\${var.name}-\${var.environment}"
  description = "Security group for \${var.name} function"
  vpc_id      = var.vpc_id
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = var.tags
}

resource "aws_iam_role" "lambda_execution" {
  name = "\${var.name}-\${var.environment}-lambda-execution"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_execution" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
`;

        outputsTf = `
# Outputs for function module
output "function_arn" {
  description = "The Lambda function ARN"
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "The Lambda function name"
  value       = aws_lambda_function.this.function_name
}

output "invoke_arn" {
  description = "The Lambda invoke ARN"
  value       = aws_lambda_function.this.invoke_arn
}
`;
        break;
      
      case 'database':
        variablesTf = `
# Variables for database module
variable "name" {
  description = "The name of the database"
  type        = string
}

variable "environment" {
  description = "The deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID"
  type        = string
}

variable "subnets" {
  description = "The subnet IDs to deploy to"
  type        = list(string)
}

variable "engine" {
  description = "The database engine"
  type        = string
  default     = "postgres"
}

variable "version" {
  description = "The database engine version"
  type        = string
  default     = "13.4"
}

variable "instance" {
  description = "The database instance type"
  type        = string
  default     = "db.t3.micro"
}

variable "storage" {
  description = "The allocated storage in GB"
  type        = number
  default     = 20
}

variable "backup_retention" {
  description = "The number of days to retain backups"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
`;

        moduleTf = `
# Database deployment module
resource "aws_db_instance" "this" {
  identifier           = "\${var.name}-\${var.environment}"
  engine               = var.engine
  engine_version       = var.version
  instance_class       = var.instance
  allocated_storage    = var.storage
  storage_type         = "gp2"
  
  name                 = replace(var.name, "-", "_")
  username             = "admin"
  password             = "TemporaryPassword123!" # Should be provided via secure methods
  
  vpc_security_group_ids = [aws_security_group.this.id]
  db_subnet_group_name   = aws_db_subnet_group.this.name
  
  backup_retention_period = var.backup_retention
  skip_final_snapshot     = true
  
  tags = var.tags
}

resource "aws_db_subnet_group" "this" {
  name       = "\${var.name}-\${var.environment}"
  subnet_ids = var.subnets
  
  tags = var.tags
}

resource "aws_security_group" "this" {
  name        = "\${var.name}-\${var.environment}-db"
  description = "Security group for \${var.name} database"
  vpc_id      = var.vpc_id
  
  # DB port based on engine type
  ingress {
    from_port   = var.engine == "postgres" ? 5432 : var.engine == "mysql" ? 3306 : 1433
    to_port     = var.engine == "postgres" ? 5432 : var.engine == "mysql" ? 3306 : 1433
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
  
  tags = var.tags
}
`;

        outputsTf = `
# Outputs for database module
output "endpoint" {
  description = "The database endpoint"
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "The database address"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "The database port"
  value       = aws_db_instance.this.port
}

output "name" {
  description = "The database name"
  value       = aws_db_instance.this.name
}
`;
        break;
      
      default:
        // Generic module for other types
        variablesTf = `
# Variables for generic module
variable "name" {
  description = "The resource name"
  type        = string
}

variable "environment" {
  description = "The deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID"
  type        = string
}

variable "subnets" {
  description = "The subnet IDs to deploy to"
  type        = list(string)
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
`;

        moduleTf = `
# Generic deployment module
# This is a placeholder that creates a CloudFormation stack
# You would typically implement specific resource types here
resource "aws_cloudformation_stack" "this" {
  name = "\${var.name}-\${var.environment}"
  
  template_body = jsonencode({
    Resources = {
      GenericResource = {
        Type = "AWS::CloudFormation::WaitConditionHandle"
        Properties = {}
      }
    }
    Outputs = {
      ResourceId = {
        Value = {
          Ref = "GenericResource"
        }
      }
    }
  })
  
  tags = var.tags
}
`;

        outputsTf = `
# Outputs for generic module
output "resource_id" {
  description = "The generic resource ID"
  value       = aws_cloudformation_stack.this.outputs["ResourceId"]
}
`;
        break;
    }
    
    // Write module files
    fs.writeFileSync(path.join(moduleDir, 'variables.tf'), variablesTf);
    fs.writeFileSync(path.join(moduleDir, 'main.tf'), moduleTf);
    fs.writeFileSync(path.join(moduleDir, 'outputs.tf'), outputsTf);
  });
  
  console.log('Successfully generated Terraform files from SCORE specification.');
  console.log(`Terraform files are in ${TERRAFORM_DIR} directory.`);
  
} catch (error) {
  console.error(`Error processing SCORE file: ${error.message}`);
  process.exit(1);
}
EOF

# Make the parser script executable
chmod +x "$PARSER_SCRIPT"

# Run the parser
print_step "Generating Terraform Configuration"
node "$PARSER_SCRIPT"

# # Create a deployment script
# print_step "Creating Terraform Deployment Script"
# cat > deploy-terraform.sh <<EOF
# #!/bin/bash
# set -e

# # Colors
# GREEN='\033[0;32m'
# YELLOW='\033[1;33m'
# RED='\033[0;31m'
# NC='\033[0m'

# cd terraform

# # Initialize Terraform
# echo -e "\${YELLOW}Initializing Terraform...${NC}"
# terraform init

# # Validate the configuration
# echo -e "\${YELLOW}Validating Terraform configuration...${NC}"
# terraform validate

# # Create a plan
# echo -e "\${YELLOW}Creating Terraform plan...${NC}"
# terraform plan -out=tfplan

# # Apply the plan
# echo -e "\${YELLOW}Applying Terraform configuration...${NC}"
# terraform apply -auto-approve tfplan

# echo -e "\${GREEN}Deployment completed successfully!${NC}"
# EOF

# # Make the deployment script executable
# chmod +x deploy-terraform.sh

# Run the deployment if requested
print_step "Ready to Deploy"
print_info "Terraform configuration has been generated from your SCORE file"
print_info "To deploy the infrastructure, run: ./deploy-terraform.sh"

print_success "SCORE to Terraform transformation completed successfully!"