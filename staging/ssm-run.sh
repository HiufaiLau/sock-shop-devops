#!/usr/bin/env bash
# Run a local shell script on the K3s server through AWS SSM and stream back
# its output. Exits non-zero if the remote script fails or times out.
#
# Usage: ssm-run.sh <instance-id> <script-file> [timeout-seconds]
#
# Used by CD instead of SSH/kubectl-over-6443, so the instance needs no
# inbound ports apart from the ALB → NodePort rule.
set -euo pipefail

INSTANCE_ID="${1:?instance id required}"
SCRIPT_FILE="${2:?script file required}"
TIMEOUT="${3:-900}"

PARAMS=$(jq -n --rawfile script "$SCRIPT_FILE" --arg t "$TIMEOUT" \
  '{commands: [$script], executionTimeout: [$t]}')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 60 \
  --parameters "$PARAMS" \
  --query "Command.CommandId" --output text)

echo "SSM command $CMD_ID sent to $INSTANCE_ID (timeout ${TIMEOUT}s)"

# `aws ssm wait command-executed` gives up after ~100s, which is too short
# for a rollout, so poll ourselves.
DEADLINE=$(( $(date +%s) + TIMEOUT + 120 ))
STATUS="Pending"
while :; do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress|Delayed) ;;
    *) break ;;
  esac
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "Timed out waiting for SSM command $CMD_ID (last status: $STATUS)"
    exit 1
  fi
  sleep 5
done

echo "----- remote stdout -----"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text
echo "----- remote stderr -----"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardErrorContent" --output text
echo "-------------------------"
echo "Status: $STATUS"

[ "$STATUS" = "Success" ]
