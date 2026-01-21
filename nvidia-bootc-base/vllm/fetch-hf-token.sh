#!/bin/bash
# Fetch Hugging Face token from AWS Secrets Manager
# This script runs at boot before vLLM starts

set -euo pipefail

LOG_PREFIX="[RHOIM fetch-hf-token]"
HF_TOKEN_FILE="/etc/vllm/hf-token.env"
HF_SECRET_NAME="${HF_SECRET_NAME:-rhoim/hf-token}"
AWS_REGION="${AWS_REGION:-us-east-1}"

log() {
    echo "$LOG_PREFIX $*"
}

err() {
    echo "$LOG_PREFIX ERROR: $*" >&2
}

# Check if token file already exists
if [[ -f "$HF_TOKEN_FILE" ]]; then
    log "Token file already exists at $HF_TOKEN_FILE, skipping fetch"
    exit 0
fi

# Check if AWS CLI is available
if ! command -v aws &>/dev/null; then
    err "AWS CLI not found. Cannot fetch HF token from Secrets Manager."
    err "Install AWS CLI or provide HF_TOKEN via /etc/sysconfig/rhoim"
    exit 1
fi

# Wait for instance metadata service (IMDS) to be available
log "Waiting for AWS Instance Metadata Service..."
for i in {1..30}; do
    if curl -s -m 2 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
        log "IMDS available"
        break
    fi
    if [[ $i -eq 30 ]]; then
        err "IMDS not available after 30 attempts. Cannot use instance role."
        exit 1
    fi
    sleep 2
done

# Attempt to detect region from instance metadata if not set
if [[ "$AWS_REGION" == "us-east-1" ]]; then
    DETECTED_REGION=$(curl -s -m 5 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
    if [[ -n "$DETECTED_REGION" ]]; then
        AWS_REGION="$DETECTED_REGION"
        log "Detected AWS region: $AWS_REGION"
    fi
fi

# Fetch the token from Secrets Manager
log "Fetching HF token from Secrets Manager (secret: $HF_SECRET_NAME, region: $AWS_REGION)"
if HF_TOKEN=$(aws secretsmanager get-secret-value \
    --secret-id "$HF_SECRET_NAME" \
    --query SecretString \
    --output text \
    --region "$AWS_REGION" 2>&1); then

    # Validate token format (should start with hf_)
    if [[ ! "$HF_TOKEN" =~ ^hf_ ]]; then
        err "Retrieved secret does not look like a valid HF token (should start with 'hf_')"
        err "Check the secret value in AWS Secrets Manager"
        exit 1
    fi

    # Create directory and write token
    mkdir -p /etc/vllm
    echo "HF_TOKEN=$HF_TOKEN" > "$HF_TOKEN_FILE"
    chmod 600 "$HF_TOKEN_FILE"
    chown root:root "$HF_TOKEN_FILE"

    # Also make available in global profile for interactive sessions
    echo "export HF_TOKEN=$HF_TOKEN" > /etc/profile.d/hf-token.sh
    chmod 644 /etc/profile.d/hf-token.sh

    log "HF token successfully retrieved and stored at $HF_TOKEN_FILE"
else
    err "Failed to fetch HF token from Secrets Manager"
    err "Response: $HF_TOKEN"
    err ""
    err "Troubleshooting:"
    err "  1. Ensure the secret '$HF_SECRET_NAME' exists in region '$AWS_REGION'"
    err "  2. Ensure the instance has an IAM role with secretsmanager:GetSecretValue permission"
    err "  3. Check CloudWatch logs for more details"
    exit 1
fi
