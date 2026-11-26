#!/usr/bin/env bash
# Print the instance ID of the staging K3s server, looked up by its Name tag.
# Terraform can replace the instance, so never hardcode the ID.
#
# Usage: staging/find-instance.sh            (uses AWS_PROFILE, default "sockshop")
#
# Staging lives in AWS account 414772274298 / eu-central-1. Override with
# AWS_PROFILE / AWS_REGION if your profile for that account has another name.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-sockshop}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"

ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=sockshop-staging-k3s-server" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

case "$ID" in
  "" | None) echo "No sockshop-staging-k3s-server instance found (profile: $AWS_PROFILE, region: $AWS_REGION)" >&2; exit 1 ;;
  *[[:space:]]*) echo "More than one staging instance found: $ID" >&2; exit 1 ;;
esac
echo "$ID"
