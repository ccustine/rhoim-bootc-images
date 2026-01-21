# Shared Hugging Face token secret module
# Can either create a new secret or reference an existing one.
# Provides IAM policy for reading the secret.

variable "secret_name" {
  description = "Name of the secret in Secrets Manager"
  type        = string
  default     = "rhoim/hf-token"
}

variable "create_secret" {
  description = "Whether to create the secret (true) or use an existing one (false)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to the secret (only used when creating)"
  type        = map(string)
  default     = {}
}

# Look up existing secret when not creating
data "aws_secretsmanager_secret" "existing" {
  count = var.create_secret ? 0 : 1
  name  = var.secret_name
}

# Create new secret when requested
# Note: The actual token value must be set manually via AWS Console or CLI
# after the secret is created, to avoid storing secrets in Terraform state
resource "aws_secretsmanager_secret" "hf_token" {
  count       = var.create_secret ? 1 : 0
  name        = var.secret_name
  description = "Hugging Face API token for model downloads"

  tags = merge({
    Project   = "rhoim-bootc"
    ManagedBy = "opentofu"
  }, var.tags)
}

locals {
  secret_arn  = var.create_secret ? aws_secretsmanager_secret.hf_token[0].arn : data.aws_secretsmanager_secret.existing[0].arn
  secret_name = var.create_secret ? aws_secretsmanager_secret.hf_token[0].name : data.aws_secretsmanager_secret.existing[0].name
}

# IAM policy document for reading the secret
data "aws_iam_policy_document" "read_hf_secret" {
  statement {
    sid    = "ReadHFSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [local.secret_arn]
  }
}

# Outputs
output "secret_arn" {
  description = "ARN of the Hugging Face token secret"
  value       = local.secret_arn
}

output "secret_name" {
  description = "Name of the Hugging Face token secret"
  value       = local.secret_name
}

output "read_policy_json" {
  description = "IAM policy JSON for reading the secret (attach to instance roles)"
  value       = data.aws_iam_policy_document.read_hf_secret.json
}
