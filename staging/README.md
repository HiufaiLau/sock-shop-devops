# Staging Environment - AWS Terraform Configuration

This directory contains Terraform configuration to deploy a K3s (lightweight Kubernetes) cluster on AWS for the Sock Shop staging environment.

## Architecture

- **VPC**: Custom VPC with public subnets across 3 availability zones
- **EC2 Instance**: Single t3.medium instance running K3s (Sock Shop + Prometheus/Grafana)
- **Application Load Balancer**: ALB to route traffic to the K3s NodePort
- **Security Groups**: The instance accepts only NodePort 30080, and only from the ALB. No SSH (22), no K3s API (6443), no public NodePorts
- **IAM Roles**: EC2 instance profile with SSM permissions (no SSH keys needed!)

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **AWS CLI** configured with credentials
3. **Terraform** >= 1.5.0
4. **GitHub OIDC deploy role** (for CI/CD): apply [github-oidc/](github-oidc/README.md) once
   and set the `AWS_DEPLOY_ROLE_ARN` variable on the GitHub `staging` environment.
   No AWS keys are stored in GitHub.

## Configuration

### Step 1: Configure terraform.tfvars

The [terraform.tfvars](terraform.tfvars) file has been created with default values. Update these settings:

```hcl
# Change to your preferred region
aws_region = "us-east-1"

# Update availability zones to match your region
azs = [
  "us-east-1a",
  "us-east-1b",
  "us-east-1c"
]
```

### Step 2: Initialize Terraform

```bash
cd staging
terraform init
```

### Step 3: Review Plan

```bash
terraform plan
```

### Step 4: Apply Configuration

```bash
terraform apply
```

## Accessing the Cluster

Ports 22 and 6443 are closed, so all access goes through AWS SSM
(needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)).

Staging is in AWS account **414772274298**, region **eu-central-1**. Use the CLI
profile for that account (`sockshop` below); a profile for another account
(e.g. `terraform_user`) fails with `AccessDeniedException ... ssm:StartSession`.
If the instance was idle-stopped, start it first with `make up` and give SSM
2-3 minutes.

```bash
export AWS_PROFILE=sockshop AWS_REGION=eu-central-1
INSTANCE_ID=$(staging/find-instance.sh)   # run from the repo root; or: terraform output -raw server_instance_id

# Shell on the node, then use kubectl there
aws ssm start-session --target "$INSTANCE_ID"
sudo kubectl get pods -A

# Or: kubectl from your laptop through an SSM tunnel to the K3s API
aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=6443,localPortNumber=6443
# (in another terminal; kubeconfig fetched via `terraform output kubeconfig_command`,
#  keep server: https://127.0.0.1:6443)
```

### Monitoring (Prometheus + Grafana)

CD deploys `deploy/kubernetes/manifests-monitoring/` into the `monitoring`
namespace. They are not exposed publicly; open them through an SSM tunnel:

```bash
# Grafana -> http://localhost:3000 (login admin / admin)
# If 3000 is already used on your machine, pick another localPortNumber (e.g. 3300).
aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=31300,localPortNumber=3000

# Prometheus -> http://localhost:9090
aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=31090,localPortNumber=9090
```

## Access the Application

https://sockshop-staging.link (Route 53 → ACM/HTTPS on the ALB → NodePort 30080).
HTTP redirects to HTTPS.

## Resources Created

| Resource | Description |
|----------|-------------|
| VPC | Custom VPC with DNS support |
| Public Subnets | 3 public subnets across AZs |
| Internet Gateway | For public internet access |
| EC2 Instance | t3.medium running Ubuntu 22.04 + K3s, Elastic IP |
| Security Groups | ALB: 80/443 from internet. Instance: 30080 from ALB only |
| IAM Role | For SSM access (no SSH needed) |
| Application Load Balancer | HTTPS (ACM) + HTTP→HTTPS redirect, routes to NodePort 30080 |
| Route 53 + ACM | `sockshop-staging.link` alias and DNS-validated certificate |
| CloudWatch alarm | Stops the instance after 30 min idle (CPU < 15%) |
| DLM snapshot policy | Snapshots the server disk daily at 03:00 UTC, keeps 7 (~$2/month) |

## Outputs

- `app_url`: **https://sockshop-staging.link**
- `alb_dns_name`, `vpc_id`, `public_subnets`
- `server_public_ip`: Elastic IP (not reachable directly; all ports closed)
- `server_instance_id`: EC2 instance ID for SSM
- `kubeconfig_command`: SSM command to fetch kubeconfig

## CI/CD Flow

```
push to staging ─▶ CI (ci.yml): complete-demo sync check, kubeconform + helm lint,
                   kind smoke test
                     │ all green
                     ▼
                   CD (cd.yml, called by CI): terraform apply ─▶ start instance if
                   idle-stopped ─▶ wait for SSM ─▶ upload manifest bundle to S3 ─▶
                   ssm-run.sh remote-deploy.sh (kubectl apply shop + monitoring,
                   rollout status, curl :30080) ─▶ curl https://sockshop-staging.link
```

- `ssm-run.sh`: runs a local script on the node via SSM and waits for it.
- `remote-deploy.sh`: what runs on the node (kubectl there, so 6443 stays closed).
- A manual redeploy: Actions → **CD (Deploy)** → Run workflow (branch `staging`).

## Cost Estimate

Approximate monthly cost (eu-central-1, running 24/7; the idle alarm stops
the instance when unused, so actual EC2 cost is lower):

- t3.medium EC2: ~$35/month
- Application Load Balancer: ~$20/month
- EBS Storage (50GB gp3): ~$5/month
- Elastic IP, Route 53 zone, data transfer: a few $/month

**Total: ~$60-70/month at 24/7**

## Troubleshooting

### SSM Agent Not Available

If SSM isn't working:
1. Check that the instance has the IAM role attached and is running (`make status` / `make up`)
2. Wait 2-3 minutes after instance start for the SSM agent to register
3. Check Systems Manager → Fleet Manager in AWS Console

### K3s Not Ready

```bash
aws ssm start-session --target $(terraform output -raw server_instance_id)
sudo cat /var/log/user-data.log
```

### Pods Pending / OOMKilled

t3.medium has 4 GiB RAM for K3s, 14 shop pods and the monitoring stack.
Check `kubectl describe node` (Allocated resources) and `free -m` on the node;
the CD log prints both when a rollout fails. If memory is the limit, raise
`master_instance_type` back to `t3.large`.

### Application Not Accessible

Check ALB target health:
```bash
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names sockshop-staging-app --query 'TargetGroups[0].TargetGroupArn' --output text)
```

## Backup and Restore

The server's disk (tag `Backup=sockshop-staging`) is snapshotted every day at
03:00 UTC by a Data Lifecycle Manager policy, and the 7 newest snapshots are
kept. It runs whether the instance is running or idle-stopped. The DLM role
`sockshop-staging-dlm` is created by the admin-applied
[github-oidc](github-oidc/README.md) stack.

From the repo root:

```bash
make snapshots                 # list snapshots, newest last
make restore AZ=b              # rebuild from the latest snapshot in eu-central-1b
make restore AZ=a SNAPSHOT=snap-0123456789abcdef0   # a specific snapshot
make restore AZ=c SNAPSHOT=none                     # fresh server, then run CD
```

[restore.sh](restore.sh) registers a temporary image from the snapshot, runs
`terraform apply -replace` on the server in the chosen AZ (Terraform shows the
plan and asks for `yes`), then removes the old server's K3s node so pods move
straight away. The Elastic IP, ALB target and idle alarm follow the new
instance. Expect about 15–20 minutes end to end.

The server's AZ is ignored by later applies, so CD does not move a restored
server back to `eu-central-1a`. App databases keep their data inside their
containers (no persistent volumes), so a restore brings back the server and
cluster as they were at snapshot time, not a copy of live shop data.

## Cleanup

```bash
terraform destroy
```

**Warning**: This will delete all resources including data!

## Security Notes

- ✅ **No inbound SSH or K3s API**: admin and CI access go through AWS SSM (IAM-authenticated)
- ✅ **Instance only reachable from the ALB** on NodePort 30080
- ✅ **HTTPS** via ACM on the ALB, HTTP redirects to HTTPS
- ⚠️ **Grafana uses admin/admin**: only reachable via SSM tunnel, but change it
- ⚠️ **ALB is public**: consider authentication for production
