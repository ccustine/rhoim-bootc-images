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
  description = "Prefix for all resource names (e.g., 'dev-rhoim-tester') - used for easy filtering and cleanup"
  type        = string
  default     = "rhoim-tester"
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
  description = "AMI ID for the instance (RHEL 9.6)"
  type        = string
  default     = "ami-0d8d3b1122e36c000"
}

variable "root_volume_size" {
  description = "Size of root volume in GB"
  type        = number
  default     = 200
}

# Local values for resource naming
locals {
  instance_name = var.instance_name != "" ? var.instance_name : var.resource_prefix
  common_tags = {
    Project     = "rhoim-bootc"
    ManagedBy   = "opentofu"
    ResourcePrefix = var.resource_prefix
  }
}

# Get common networking info
module "network" {
  source = "../modules/aws-network"
}

# Security group for the GPU host instance
resource "aws_security_group" "gpu_host" {
  name        = "${local.instance_name}-sg"
  description = "Security group for RHEL 9.6 GPU host instance"
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

# GPU host instance
resource "aws_instance" "gpu_host" {
  ami           = var.ami_id
  instance_type = var.instance_type

  subnet_id                   = module.network.first_subnet_id
  vpc_security_group_ids      = [aws_security_group.gpu_host.id]
  associate_public_ip_address = true

  key_name = var.key_name

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
  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Log output to file for debugging
    exec > >(tee /var/log/user-data.log) 2>&1

    echo "Starting RHEL 9.6 GPU instance setup - $(date)"

    # Step 1: Install bootc and container tools
    echo "=== Installing bootc, podman, and container tools ==="
    dnf -y install bootc podman skopeo

    # Enable and start podman socket
    systemctl enable --now podman.socket

    # Step 2: Upgrade OpenSSL to fix bootc library compatibility
    echo "=== Upgrading OpenSSL for bootc compatibility ==="
    dnf -y upgrade openssl openssl-libs

    # Step 3: Install specific kernel version and pin it
    echo "=== Installing kernel 5.14.0-611.5.1 and pinning ==="
    KERNEL_VERSION="5.14.0-611.5.1.el9_7"

    # Install the specific kernel version
    dnf -y install \
      kernel-$${KERNEL_VERSION} \
      kernel-core-$${KERNEL_VERSION} \
      kernel-modules-$${KERNEL_VERSION} \
      kernel-modules-core-$${KERNEL_VERSION}

    # Set the specific kernel as default
    grubby --set-default /boot/vmlinuz-$${KERNEL_VERSION}.x86_64

    # Remove all other kernels
    echo "=== Removing other kernel versions ==="
    rpm -qa | grep -E '^kernel(-core|-modules|-modules-core)?-[0-9]' | grep -v "$${KERNEL_VERSION}" | xargs -r dnf -y remove || true

    # Pin kernel packages to prevent updates
    echo "=== Pinning kernel packages ==="
    dnf -y install python3-dnf-plugin-versionlock
    dnf versionlock add kernel kernel-core kernel-modules kernel-modules-core

    # Also exclude kernel from updates in dnf.conf as backup
    if ! grep -q "^exclude=kernel" /etc/dnf/dnf.conf; then
      echo "exclude=kernel*" >> /etc/dnf/dnf.conf
    fi

    # Step 4: Add NVIDIA CUDA repository and install precompiled driver
    echo "=== Adding NVIDIA CUDA repository ==="
    dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo

    # Step 5: Install NVIDIA driver using precompiled modules
    echo "=== Installing NVIDIA driver 570 with precompiled kernel modules ==="
    dnf -y module install nvidia-driver:570

    # Step 6: Install NVIDIA Container Toolkit
    echo "=== Installing NVIDIA Container Toolkit ==="
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
      tee /etc/yum.repos.d/nvidia-container-toolkit.repo

    dnf -y install --nogpgcheck nvidia-container-toolkit

    # Step 7: Create systemd service to complete NVIDIA setup after reboot
    echo "=== Creating post-reboot NVIDIA setup service ==="
    cat > /etc/systemd/system/nvidia-post-boot-setup.service <<'SYSTEMD_EOF'
    [Unit]
    Description=NVIDIA Driver Post-Boot Setup
    After=network.target
    ConditionPathExists=!/var/lib/nvidia-setup-complete

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/nvidia-post-boot-setup.sh
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    SYSTEMD_EOF

    # Create the post-boot setup script
    cat > /usr/local/bin/nvidia-post-boot-setup.sh <<'SCRIPT_EOF'
    #!/bin/bash
    set -e

    exec > >(tee -a /var/log/nvidia-post-boot-setup.log) 2>&1

    echo "Running NVIDIA post-boot setup - $(date)"

    echo "=== Verifying NVIDIA driver installation ==="
    if nvidia-smi; then
        echo "NVIDIA driver installed successfully"
    else
        echo "WARNING: nvidia-smi failed, driver may need attention"
        exit 1
    fi

    echo "=== Generating CDI configuration ==="
    nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

    echo "=== Setting GPU device permissions ==="
    chmod 666 /dev/nvidia* 2>/dev/null || true

    cat > /etc/udev/rules.d/70-nvidia.rules <<'UDEV_EOF'
    KERNEL=="nvidia*", MODE="0666"
    UDEV_EOF

    udevadm control --reload-rules

    echo "=== NVIDIA setup complete - $(date) ==="
    touch /var/lib/nvidia-setup-complete

    SCRIPT_EOF

    chmod +x /usr/local/bin/nvidia-post-boot-setup.sh

    systemctl enable nvidia-post-boot-setup.service

    # Step 8: Schedule reboot
    echo "=== Setup complete, scheduling reboot ==="
    shutdown -r +1 "Rebooting to complete NVIDIA GPU setup"
  EOF
}

# Outputs
output "instance_id" {
  value = aws_instance.gpu_host.id
}

output "public_ip" {
  value = aws_instance.gpu_host.public_ip
}

output "public_dns" {
  value = aws_instance.gpu_host.public_dns
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.gpu_host.public_ip}"
}
