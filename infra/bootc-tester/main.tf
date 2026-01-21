terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "resource_prefix" {
  description = "Prefix for all resource names (e.g., 'dev-rhoim-bootc-tester') - used for easy filtering and cleanup"
  type        = string
  default     = "rhoim-bootc-tester"
}

variable "instance_name" {
  description = "Name tag for the EC2 instance (will use resource_prefix if not set)"
  type        = string
  default     = ""
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access (e.g., [\"YOUR_IP/32\"])"
  type        = list(string)
}

variable "api_cidr_blocks" {
  description = "CIDR blocks allowed for API access (port 8000, e.g., [\"YOUR_IP/32\"])"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type (GPU instance)"
  type        = string
  default     = "g4dn.xlarge"
}

variable "ami_id" {
  description = "AMI ID for the bootc image (nvidia-bootc-base)"
  type        = string
  # default     = "ami-0c61973841f4985d0"
}

variable "root_volume_size" {
  description = "Size of root volume in GB"
  type        = number
  default     = 50
}

# Red Hat Subscription Manager credentials
variable "rhsm_activation_key" {
  description = "Red Hat Subscription Manager activation key"
  type        = string
  sensitive   = true
}

variable "rhsm_org_id" {
  description = "Red Hat Subscription Manager organization ID"
  type        = string
  sensitive   = true
}

# Local values for resource naming
locals {
  instance_name = var.instance_name != "" ? var.instance_name : var.resource_prefix
  common_tags = {
    Project        = "rhoim-bootc"
    ManagedBy      = "opentofu"
    ResourcePrefix = var.resource_prefix
  }
}

# Get common networking info
module "network" {
  source = "../modules/aws-network"
}

# Hugging Face token secret (shared module)
# Set create_secret = false to use existing secret, true to create new one
module "hf_secret" {
  source        = "../modules/hf-secret"
  create_secret = false  # Use existing secret
}

# IAM role for bootc-tester instance
resource "aws_iam_role" "bootc_tester" {
  name = "${local.instance_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = merge({
    Name = "${local.instance_name}-role"
  }, local.common_tags)
}

# Policy for reading HF token from Secrets Manager
resource "aws_iam_role_policy" "read_hf_secret" {
  name   = "${local.instance_name}-hf-secret-policy"
  role   = aws_iam_role.bootc_tester.id
  policy = module.hf_secret.read_policy_json
}

# Instance profile to attach role to EC2
resource "aws_iam_instance_profile" "bootc_tester" {
  name = "${local.instance_name}-profile"
  role = aws_iam_role.bootc_tester.name

  tags = merge({
    Name = "${local.instance_name}-profile"
  }, local.common_tags)
}

# Security group for the bootc-tester instance
resource "aws_security_group" "bootc_tester" {
  name        = "${local.instance_name}-sg"
  description = "Security group for RHOIM bootc tester instance"
  vpc_id      = module.network.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # vLLM API port
  ingress {
    description = "vLLM API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = var.api_cidr_blocks
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({
    Name = "${local.instance_name}-sg"
  }, local.common_tags)
}

# Bootc tester instance
resource "aws_instance" "bootc_tester" {
  ami           = var.ami_id
  instance_type = var.instance_type

  subnet_id                   = module.network.first_subnet_id
  vpc_security_group_ids      = [aws_security_group.bootc_tester.id]
  associate_public_ip_address = true

  key_name             = var.key_name
  iam_instance_profile = aws_iam_instance_profile.bootc_tester.name

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data_base64 = base64encode(local.user_data)

  tags = merge({
    Name = local.instance_name
  }, local.common_tags)

  # Tag the EBS volume with the same tags for easy filtering
  volume_tags = merge({
    Name = "${local.instance_name}-root"
  }, local.common_tags)
}

locals {
  # Minimal user_data for bootc image - NVIDIA drivers and tools are already baked in
  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Log output to file for debugging
    exec > >(tee /var/log/user-data.log) 2>&1

    echo "Starting RHOIM bootc-tester setup - $(date)"

    # The bootc image has NVIDIA drivers, container toolkit, and tools pre-installed.
    # This script verifies everything works and generates device-specific CDI config.

    # Step 1: Register with Red Hat Subscription Manager
    echo "=== Registering with Red Hat Subscription Manager ==="
    if subscription-manager status &>/dev/null; then
      echo "Already registered with RHSM"
    else
      subscription-manager register \
        --activationkey="${var.rhsm_activation_key}" \
        --org="${var.rhsm_org_id}" || echo "RHSM registration failed - continuing"
    fi

    # Step 2: Fetch Hugging Face token from Secrets Manager
    echo "=== Fetching Hugging Face token from Secrets Manager ==="
    HF_SECRET_NAME="${module.hf_secret.secret_name}"

    # Wait for instance metadata service to be available
    for i in {1..10}; do
      if curl -s -m 2 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
        break
      fi
      echo "Waiting for IMDS... ($i/10)"
      sleep 2
    done

    # Fetch the token using AWS CLI (uses instance role credentials)
    if HF_TOKEN=$(aws secretsmanager get-secret-value \
        --secret-id "$HF_SECRET_NAME" \
        --query SecretString \
        --output text \
        --region ${var.aws_region} 2>/dev/null); then

      # Create environment file for vLLM and other services
      mkdir -p /etc/vllm
      echo "HF_TOKEN=$HF_TOKEN" > /etc/vllm/hf-token.env
      chmod 600 /etc/vllm/hf-token.env

      # Also set in global environment for all users/services
      echo "HF_TOKEN=$HF_TOKEN" > /etc/profile.d/hf-token.sh
      chmod 644 /etc/profile.d/hf-token.sh

      echo "[SUCCESS] Hugging Face token retrieved and stored"
    else
      echo "[WARNING] Failed to fetch HF token - models requiring auth will not work"
      echo "[WARNING] Ensure the secret '$HF_SECRET_NAME' exists and has a value"
    fi

    # Step 3: Wait for NVIDIA driver to be ready
    echo "=== Waiting for NVIDIA driver ==="
    for i in {1..30}; do
      if nvidia-smi &>/dev/null; then
        echo "NVIDIA driver ready"
        break
      fi
      echo "Waiting for NVIDIA driver... ($i/30)"
      sleep 2
    done

    # Step 4: Verify NVIDIA driver
    echo "=== Verifying NVIDIA driver ==="
    nvidia-smi

    # Step 5: Generate CDI configuration (device-specific)
    echo "=== Generating CDI configuration ==="
    mkdir -p /etc/cdi
    nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

    # Step 6: Enable podman socket
    echo "=== Enabling podman socket ==="
    systemctl enable --now podman.socket

    # Step 7: Verify bootc status
    echo "=== Bootc status ==="
    bootc status

    echo "=== RHOIM bootc-tester setup complete - $(date) ==="
  EOF
}

# Outputs
output "instance_id" {
  value = aws_instance.bootc_tester.id
}

output "public_ip" {
  value = aws_instance.bootc_tester.public_ip
}

output "public_dns" {
  value = aws_instance.bootc_tester.public_dns
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.bootc_tester.public_ip}"
}

output "ami_id" {
  value = var.ami_id
}

output "hf_secret_name" {
  description = "Name of the Secrets Manager secret for HF token (set value via AWS Console or CLI)"
  value       = module.hf_secret.secret_name
}

output "hf_secret_arn" {
  description = "ARN of the Secrets Manager secret for HF token"
  value       = module.hf_secret.secret_arn
}
