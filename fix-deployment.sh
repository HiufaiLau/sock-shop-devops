#!/usr/bin/env bash
# Manually redeploy Sock Shop + monitoring to staging from your local checkout,
# the same way CD does: bundle the manifests, upload to S3, run
# staging/remote-deploy.sh on the node through SSM.
#
# Normally you don't need this: pushing to `staging` (or Actions → CD (Deploy)
# → Run workflow) does the same after CI passes. This deploys whatever is in
# your working tree, unreviewed, so use it only to recover a broken staging.
#
# Uses AWS_PROFILE (default "sockshop", account 414772274298) and eu-central-1.
set -euo pipefail
cd "$(dirname "$0")"

export AWS_PROFILE="${AWS_PROFILE:-sockshop}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"
BUCKET="sockshop-terraform-state-414772274298"
KEY="deploy-bundles/staging/manual-$(date +%Y%m%d%H%M%S).tgz"

echo "🔧 Redeploying Sock Shop staging from local checkout (profile: $AWS_PROFILE)"
echo "=================================="

INSTANCE_ID=$(staging/find-instance.sh)
STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)
if [ "$STATE" != "running" ]; then
  echo "Instance $INSTANCE_ID is $STATE. Start it first with: make up (then wait ~2-3 min for SSM)"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; aws s3 rm "s3://$BUCKET/$KEY" >/dev/null 2>&1 || true' EXIT

echo "📦 Uploading manifest bundle"
tar -czf "$WORK/bundle.tgz" deploy/kubernetes/complete-demo.yaml deploy/kubernetes/manifests-monitoring
aws s3 cp "$WORK/bundle.tgz" "s3://$BUCKET/$KEY" --only-show-errors
URL=$(aws s3 presign "s3://$BUCKET/$KEY" --expires-in 1800)

BUNDLE_URL="$URL" python3 -c '
import os, sys
s = open("staging/remote-deploy.sh").read()
open(sys.argv[1], "w").write(s.replace("__BUNDLE_URL__", os.environ["BUNDLE_URL"]))
' "$WORK/remote-deploy.sh"

echo "🚀 Running remote-deploy.sh on $INSTANCE_ID (can take ~10 min)"
staging/ssm-run.sh "$INSTANCE_ID" "$WORK/remote-deploy.sh" 1500

echo ""
echo "✅ Done. Check: ./check-deployment-status.sh  or  https://sockshop-staging.link"
