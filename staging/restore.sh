#!/usr/bin/env bash
# Rebuild the staging k3s server in any Availability Zone, from the latest
# daily snapshot of its disk (or from a fresh image).
#
# Usage: staging/restore.sh <a|b|c> [latest|<snapshot-id>|none]
#   a|b|c        AZ to build in (eu-central-1a/b/c)
#   latest       newest daily snapshot (default)
#   <snap-id>    a specific snapshot, e.g. snap-0123456789abcdef0
#   none         no snapshot: fresh Ubuntu + K3s; run CD afterwards to deploy
#
# Normally run as `make restore AZ=b` from the repo root.
#
# What it does:
#   1. Registers a temporary image (AMI) from the snapshot.
#   2. terraform apply -replace on the server, in the chosen AZ. Terraform
#      shows the plan and asks for "yes" before anything is destroyed.
#      The Elastic IP, ALB target and idle alarm follow the new instance.
#   3. Deregisters the temporary image (the snapshot is kept).
#   4. Waits for SSM, then removes the old server's node entry from K3s so
#      pods move to the new node straight away.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-sockshop}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"
cd "$(dirname "$0")"

AZ="${1:?usage: restore.sh <a|b|c> [latest|<snapshot-id>|none]}"
SNAP="${2:-latest}"
ENV_NAME=staging

case "$AZ" in
  a) IDX=0 ;; b) IDX=1 ;; c) IDX=2 ;;
  *) echo "AZ must be a, b or c (got '$AZ')" >&2; exit 1 ;;
esac

if [ "$SNAP" = "latest" ]; then
  SNAP=$(aws ec2 describe-snapshots --owner-ids self \
    --filters "Name=tag:Backup,Values=sockshop-$ENV_NAME" "Name=status,Values=completed" \
    --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId' --output text)
  if [ -z "$SNAP" ] || [ "$SNAP" = "None" ]; then
    echo "No completed snapshots tagged Backup=sockshop-$ENV_NAME yet." >&2
    echo "The first one is taken at 03:00 UTC. Use 'none' to rebuild from a fresh image." >&2
    exit 1
  fi
fi

AMI=""
VARS=(-var "server_subnet_index=$IDX")
if [ "$SNAP" != "none" ]; then
  read -r SNAP_TIME SNAP_SIZE < <(aws ec2 describe-snapshots --snapshot-ids "$SNAP" \
    --query 'Snapshots[0].[StartTime,VolumeSize]' --output text)
  echo "Restoring from $SNAP (taken $SNAP_TIME, ${SNAP_SIZE} GiB) into eu-central-1$AZ"

  # Keep the boot mode of the current server, if there is one.
  OLD_ID=$(./find-instance.sh 2>/dev/null || true)
  BOOT_MODE=legacy-bios
  if [ -n "$OLD_ID" ]; then
    BM=$(aws ec2 describe-instances --instance-ids "$OLD_ID" \
      --query 'Reservations[0].Instances[0].CurrentInstanceBootMode' --output text)
    case "$BM" in legacy-bios|uefi) BOOT_MODE=$BM ;; esac
  fi

  AMI=$(aws ec2 register-image \
    --name "sockshop-$ENV_NAME-restore-$(date -u +%Y%m%d-%H%M%S)" \
    --architecture x86_64 --virtualization-type hvm --ena-support \
    --boot-mode "$BOOT_MODE" --root-device-name /dev/sda1 \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$SNAP,VolumeType=gp3,DeleteOnTermination=true}" \
    --query ImageId --output text)
  # Clean up the temporary image however this script exits.
  trap 'echo "Deregistering temporary image $AMI"; aws ec2 deregister-image --image-id "$AMI" || true' EXIT
  echo "Temporary image $AMI registered; waiting for it to be available..."
  aws ec2 wait image-available --image-ids "$AMI"
  VARS+=(-var "restore_ami_id=$AMI")
else
  echo "Rebuilding from a fresh Ubuntu image into eu-central-1$AZ (no snapshot)"
fi

terraform init -input=false >/dev/null
terraform apply -input=false -replace=aws_instance.k3s_server "${VARS[@]}"

NEW_ID=$(terraform output -raw server_instance_id)
echo "New server: $NEW_ID. Waiting for it to come online in SSM (can take ~5 minutes)..."
for _ in $(seq 60); do
  PING=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$NEW_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
  [ "$PING" = "Online" ] && break
  sleep 10
done
if [ "$PING" != "Online" ]; then
  echo "Server not online in SSM after 10 minutes. Check it, then run CD (Deploy)." >&2
  exit 1
fi

if [ "$SNAP" = "none" ]; then
  echo "Fresh server is up. Run Actions -> CD (Deploy) to install the shop and monitoring."
  exit 0
fi

# The restored disk still lists the old server as a K3s node. Remove it so its
# pods are recreated on the new node now instead of after the 5-minute timeout.
CLEANUP=$(mktemp)
cat > "$CLEANUP" <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
ME=$(hostname)
for _ in $(seq 90); do
  kubectl get node "$ME" >/dev/null 2>&1 && break
  sleep 10
done
kubectl get nodes --no-headers | awk -v me="$ME" '$1 != me {print $1}' | xargs -r kubectl delete node
kubectl get nodes -o wide
EOF
bash ./ssm-run.sh "$NEW_ID" "$CLEANUP" 1200
rm -f "$CLEANUP"

echo
echo "Restore complete. The shop should be back at https://sockshop-$ENV_NAME.link within a few minutes."
echo "Optional: run Actions -> CD (Deploy) to redeploy the latest manifests."
