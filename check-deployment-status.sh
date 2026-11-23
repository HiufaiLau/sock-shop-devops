#!/usr/bin/env bash
# Check the staging Sock Shop deployment: instance state, ALB target health,
# the public URL, and pod status (via SSM, since the instance has no open ports).
#
# Uses AWS_PROFILE (default "sockshop", account 414772274298) and eu-central-1.
set -uo pipefail
cd "$(dirname "$0")"

export AWS_PROFILE="${AWS_PROFILE:-sockshop}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"
APP_URL="https://sockshop-staging.link"

echo "🔍 Checking Sock Shop staging (profile: $AWS_PROFILE, region: $AWS_REGION)"
echo "=========================================="

INSTANCE_ID=$(staging/find-instance.sh) || exit 1
STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)
echo "🖥️  Instance: $INSTANCE_ID ($STATE)"

echo ""
echo "📊 Load Balancer Target Health:"
ALB_ARN=$(aws elbv2 describe-load-balancers --names sockshop-staging-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
  --output table

echo ""
echo -n "🌐 $APP_URL: "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$APP_URL" --max-time 10)
if [ "$HTTP_CODE" == "200" ]; then
  echo "✅ Working! (HTTP $HTTP_CODE)"
else
  echo "⏳ Not ready (HTTP $HTTP_CODE)"
fi

if [ "$STATE" != "running" ]; then
  echo ""
  echo "Instance is $STATE (the idle alarm stops it after 30 min). Start it with: make up"
  exit 0
fi

echo ""
echo "📋 Pods (via SSM):"
REMOTE=$(mktemp)
trap 'rm -f "$REMOTE"' EXIT
cat > "$REMOTE" <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -n sock-shop
echo
kubectl get pods -n monitoring
EOF
staging/ssm-run.sh "$INSTANCE_ID" "$REMOTE" 120
