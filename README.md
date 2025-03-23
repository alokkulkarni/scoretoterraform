# SCORE to Terraform Deployment System

This system allows you to convert SCORE (Standardized Cloud Resource Environment) workload definitions into Terraform infrastructure-as-code and deploy them to your cloud provider.

## Overview

SCORE is a standardized specification for defining cloud workloads in a cloud-agnostic way. This tool parses SCORE YAML files and generates equivalent Terraform configurations that can be deployed to AWS, Azure, or GCP (with AWS being the primary target in this implementation).

## Files Included

1. **deploy-script.sh**: Main shell script that orchestrates the entire deployment process
2. **sample-score.yaml**: Example SCORE file showing the structure and supported resources
3. **deploy-terraform.sh**: Shell script to deploy the terraform configuration. - defaults to AWS but can be modified for other cloud providers.

## Prerequisites

- Node.js (v14+) and npm
- Terraform (v1.0+)
- AWS CLI (if deploying to AWS) with configured credentials
- Bash shell environment

## Supported Workload Types

- **container**: Deploys as ECS services on AWS
- **function**: Deploys as Lambda functions on AWS
- **database**: Deploys as RDS instances on AWS

## Customizing the Deployment

You can customize the deployment by:

1. Modifying your `score.yaml` file with specific resource configurations
2. Directly editing the generated Terraform files after parsing but before deployment
3. Extending the parser script to support additional SCORE resource types

# Deploying Nginx on AWS ECS using SCORE

This guide walks you through the process of deploying a Nginx web server on AWS ECS using the SCORE to Terraform conversion scripts.

# Nginx on AWS ECS with Load Balancer: Implementation Guide

This guide explains the implementation of a publicly accessible Nginx service on AWS ECS with an Application Load Balancer, deployed using our SCORE to Terraform conversion tools.

## Architecture Overview

The updated implementation creates the following AWS resources:

1. **Virtual Private Cloud (VPC)**
   - Private subnets for ECS tasks
   - Public subnets for the load balancer
   - NAT Gateway for private subnet internet access

2. **ECS Infrastructure**
   - ECS Cluster to manage container instances
   - Task Definition with Nginx container configuration
   - ECS Service to maintain desired task count
   - Health checks to ensure container availability

3. **Load Balancer Components**
   - Application Load Balancer in public subnets
   - Target Group for routing traffic to containers
   - HTTP Listener on port 80
   - Security Groups for controlled access

4. **Security Elements**
   - IAM Roles with appropriate permissions
   - Security Groups with minimal required access
   - Docker Hub image pull policy

## Key Features

### Internet Accessibility

The solution provides internet accessibility through:

- An Application Load Balancer deployed in public subnets
- HTTP listener on port 80 accepting traffic from any source (0.0.0.0/0)
- Security groups configured to allow public access

### Enhanced Container Configuration

The container deployment includes:

- Health check integration for automatic container replacement
- Multiple replicas for high availability
- Container-level environment variables
- CloudWatch logging for operational visibility

### Infrastructure as Code

The entire infrastructure is deployed using:

- SCORE YAML for high-level workload definition
- Generated Terraform configurations for provisioning
- Modular architecture for maintainability

## Deployment Process

### 1. Generate Terraform Configuration

The `deploy-script.sh` parses the SCORE YAML file and generates Terraform configurations including:

- VPC and networking components
- ECS cluster, tasks, and services
- Load balancer and target groups
- Security groups and IAM roles

### 2. Deploy Infrastructure

The `deploy-terraform.sh` script:

- Initializes Terraform
- Creates a deployment plan
- Provisions all AWS resources
- Outputs the load balancer URL

### 3. Access the Application

After deployment, the load balancer URL is provided in the outputs, allowing immediate access to the Nginx service via a web browser.

## Operational Considerations

### Monitoring and Logging

- Container logs are streamed to CloudWatch
- Health checks ensure automatic recovery
- Load balancer metrics available in CloudWatch

### Scaling

- The ECS service can be scaled horizontally by adjusting the replica count
- Vertical scaling possible by modifying CPU and memory allocations

### Clean-up

The enhanced destroy functionality:

- Properly scales down ECS services
- Removes load balancer components
- Deletes security groups and IAM roles
- Destroys the VPC and networking components

## Conclusion

This implementation provides a production-ready Nginx deployment that is:

1. **Reliable** - With health checks and multiple replicas
2. **Accessible** - Through a public load balancer
3. **Secure** - With properly configured IAM roles and security groups
4. **Manageable** - Using infrastructure as code principles


## Step 1: Set Up Your Environment

Create a project directory and copy all the necessary files as created in the examples folder:

```bash
mkdir nginx-ecs-deployment
cd nginx-ecs-deployment
```

## Step 2: Create the SCORE YAML File

Create a file named `score.yaml` with the provided SCORE configuration:

```yaml
# Copy the content from the simple-nginx-score file
```

This SCORE file defines:
- A simple Nginx container workload
- Resource requirements (CPU, memory)
- Port configuration
- VPC networking setup
- Load balancer configuration

## Step 3: Install Dependencies

Install the required Node.js dependencies:

```bash
npm init -y
npm install js-yaml
```

## Step 4: Parse SCORE to Terraform

Run the SCORE parser script to generate Terraform configurations:

```bash
chmod +x deploy-script.sh
./deploy-script.sh
```

This will:
- Parse the SCORE YAML file
- Generate appropriate Terraform files in the `terraform/` directory
- Create module structures for each resource type
- Generate a deployment script for Terraform

## Step 5: Review Generated Terraform Configuration

Examine the generated Terraform files to ensure they match your expectations:

```bash
ls -la terraform/
cat terraform/main.tf
```

## Step 6: Deploy the Infrastructure

Run the deployment script to create the infrastructure on AWS:

```bash
chmod +x deploy-terraform.sh
./deploy-terraform.sh
```

This will:
1. Initialize Terraform
2. Create an execution plan
3. Ask for confirmation
4. Apply the configuration to AWS
5. Output the deployment results

## Step 7: Access Your Nginx Deployment

After successful deployment, the script will output:
- The load balancer DNS name
- The ECS cluster name
- Other relevant information

You can access your Nginx server by visiting the load balancer DNS in your web browser.

## Step 8: Clean Up (Optional)

When you're finished with the deployment, you can clean up all resources:

```bash
./deploy-terraform.sh --destroy
```

This will remove all AWS resources created by this deployment.

## Troubleshooting

If you encounter issues:

1. Check the AWS console for detailed error messages
2. Verify your AWS credentials are properly configured
3. Ensure all required AWS services are enabled in your account
4. Review the Terraform logs for detailed error information

## Customization

To customize your Nginx deployment:
1. Modify the `score.yaml` file with your specific requirements
2. Re-run the parser and deployment scripts
3. For advanced customization, you can directly edit the generated Terraform files

## Next Steps

Once your basic Nginx deployment is working, you might want to:
1. Add custom Nginx configuration
2. Set up HTTPS with SSL certificates
3. Implement auto-scaling based on traffic patterns
4. Add monitoring and logging solutions

## Troubleshooting

If you encounter issues:

1. Check your SCORE file syntax with a YAML validator
2. Verify that your cloud provider credentials are properly configured
3. Review the generated Terraform files for any configuration errors
4. Check Terraform logs for detailed error messages during deployment

## Advanced Configuration

For advanced configurations, you may need to:

1. Customize the module templates in the parser script
2. Add support for additional resource types
3. Implement provider-specific optimizations
4. Configure remote state storage for Terraform

## Security Considerations

- The sample code uses placeholder credentials and passwords
- For production use, implement secure credential management using AWS Secrets Manager, environment variables, or Terraform variables
- Review IAM permissions to ensure least privilege

## Contributing

Feel free to extend and improve this tool by:

1. Adding support for additional SCORE resource types
2. Implementing multi-cloud provider support
3. Enhancing error handling and validation
4. Creating a more robust deployment pipeline

## License

This tool is provided under the MIT License.