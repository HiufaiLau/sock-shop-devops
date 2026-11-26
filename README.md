# Sock Shop on AWS (staging)

This repo runs Weaveworks' [Sock Shop](https://github.com/microservices-demo/microservices-demo) microservices demo on AWS. The application images are upstream; this fork adds the infrastructure (Terraform), the CI/CD pipeline, monitoring, backups and locked-down access.

Staging runs on one EC2 instance (t3.medium) running K3s behind an Application Load Balancer, in AWS account 414772274298, region eu-central-1. The app is at **https://sockshop-staging.link**.

Day to day you only need the [Makefile](Makefile) at the repo root.

| Doc | What's in it |
|---|---|
| [staging/README.md](staging/README.md) | Full staging setup: Terraform, deploy, access, backup and restore |
| [staging/github-oidc/README.md](staging/github-oidc/README.md) | One-time GitHub OIDC deploy role (no AWS keys in GitHub) |
| [DEPLOYMENT_SUMMARY.md](DEPLOYMENT_SUMMARY.md) | Short summary of the current setup |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Known problems and fixes |

## Quick reference

| Command | What it does |
|---|---|
| `make up` | Starts the instance. The app is ready in about 2 minutes. If the instance is still stopping, it waits for it to stop first. |
| `make down` | Stops the instance. |
| `make status` | Shows the instance state (`running`, `stopped`, …). |
| `make url` | Prints the app URL. |
| `make snapshots` | Lists the daily disk snapshots, newest last. |
| `make restore AZ=b` | Rebuilds the server from the latest snapshot in another AZ (about 15–20 minutes). |

The instance also **stops by itself after 30 minutes idle** (CPU below 15%), so you will often find it stopped and need `make up` first. The threshold is 15% because the node never drops below about 12% CPU even when nobody is using it.

The Makefile looks the instance up by its Name tag ([staging/find-instance.sh](staging/find-instance.sh)), so it keeps working after the instance is recreated or restored.

## Prerequisites

- **AWS CLI** with a profile for account 414772274298. The Makefile expects the profile to be named `sockshop`; if yours has another name, run `export AWS_PROFILE=<your-profile>`. A profile for a different account fails with `AccessDeniedException` (or a Terraform state lock error).
- **Terraform 1.5.0 or newer**, only to create or change the infrastructure.
- **AWS Session Manager plugin**, to get onto the node. Ports 22 and 6443 are closed, so all access goes through SSM.

## Install (one-time setup)

### 1. GitHub OIDC deploy role

CI/CD authenticates to AWS with GitHub OIDC, so no AWS keys are stored in GitHub. An admin applies [staging/github-oidc](staging/github-oidc/README.md) once and sets `AWS_DEPLOY_ROLE_ARN` on the GitHub `staging` environment. That stack also creates the role the daily snapshot policy uses.

### 2. Infrastructure

Only needed if the environment does not exist yet or is being rebuilt:

```bash
cd staging
cp terraform.tfvars.example terraform.tfvars   # region eu-central-1; set the AZs to match
terraform init
terraform plan
terraform apply
```

This creates the VPC (3 public subnets), the EC2/K3s instance with an Elastic IP, the ALB with HTTPS (ACM certificate), the Route 53 record, the CloudWatch idle-stop alarm and the daily snapshot policy. State is in S3 with a DynamoDB lock. Details are in [staging/README.md](staging/README.md).

### 3. Deploy the app

Deployment is automatic. A push to the `staging` branch runs CI; if CI is green, CD deploys. See [CI/CD](#cicd) below.

To redeploy by hand: in GitHub Actions, open **CD (Deploy)** and choose **Run workflow** on branch `staging`.

## Access

### Shell on the node

```bash
export AWS_PROFILE=sockshop AWS_REGION=eu-central-1
aws ssm start-session --target $(staging/find-instance.sh)
sudo kubectl get pods -A
```

If the instance was idle-stopped, run `make up` first and give SSM 2 to 3 minutes.

### Grafana and Prometheus

Both run in the `monitoring` namespace and are not public. Open them through SSM port forwarding:

```bash
INSTANCE_ID=$(staging/find-instance.sh)

# Grafana: http://localhost:3000 (login admin / admin)
aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=31300,localPortNumber=3000

# Prometheus: http://localhost:9090
aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=31090,localPortNumber=9090
```

If port 3000 is already in use on your machine, pick another `localPortNumber`, for example 3300.

Grafana loads its Prometheus datasource and all 6 dashboards from ConfigMaps in [20-grafana-configmap.yaml](deploy/kubernetes/manifests-monitoring/20-grafana-configmap.yaml) on every start, so a restart no longer wipes them. To change a dashboard, edit that file and deploy. A password changed in the Grafana UI is lost when the pod restarts.

### How SSM access works

AWS Systems Manager (SSM) replaces SSH. The SSM Agent on the instance makes an outbound HTTPS connection to the SSM service, so the instance needs no inbound admin ports and nobody needs SSH keys. IAM decides who gets in:

- The instance role has `AmazonSSMManagedInstanceCore`, which lets the agent register.
- Your AWS profile, or the CI role, needs permissions such as `ssm:StartSession` and `ssm:SendCommand`.
- CloudTrail logs every session and command.

This project uses three SSM features:

- **Session Manager** (`aws ssm start-session`): a shell on the node.
- **Port forwarding** (`AWS-StartPortForwardingSession`): Grafana, Prometheus and the K3s API on your machine.
- **Run Command** (`aws ssm send-command`): how CD runs the deploy script on the node, through [staging/ssm-run.sh](staging/ssm-run.sh).

Common problems:

- Instance missing from `aws ssm describe-instance-information`: the agent isn't registered. Check that the instance is running, its role, and its outbound internet access.
- Commands time out: the instance is overloaded.
- `start-session` fails locally: the Session Manager plugin isn't installed.
- SSM itself is down: EC2 Instance Connect won't help (it needs port 22). Use the EC2 Serial Console, or open port 22 to your own IP only and close it again afterwards.

## CI/CD

**CI** ([ci.yml](.github/workflows/ci.yml)) runs on every push and pull request:

1. **Manifest sync check**: `complete-demo.yaml` matches its source manifests.
2. **Validation**: kubeconform, `helm lint`, and validation of the rendered Helm chart.
3. **Kind smoke test** (needs 1 and 2): creates a Kubernetes cluster on the runner, deploys everything, waits for all rollouts and curls the front-end.

**CD** ([cd.yml](.github/workflows/cd.yml)) runs only when all three CI jobs are green and the push is to `staging`. It:

1. Assumes the deploy role through GitHub OIDC.
2. Runs `terraform apply`, so the infrastructure matches the code.
3. Starts the instance if the idle alarm stopped it, and waits for the SSM agent.
4. Uploads the manifests to S3 behind a 30-minute presigned link.
5. Runs `kubectl apply` on the node over SSM (no SSH).
6. Checks https://sockshop-staging.link end to end, then deletes the bundle from S3.

CD deploys exactly the commit CI tested, and a concurrency group stops two deploys running at once.

## Backup and restore

A Data Lifecycle Manager policy snapshots the server's 50 GB disk every day at 03:00 UTC and keeps 7 (about $2/month). It runs whether the instance is running or stopped.

```bash
make snapshots                                      # list snapshots
make restore AZ=b                                   # latest snapshot, into eu-central-1b
make restore AZ=a SNAPSHOT=snap-0123456789abcdef0   # a specific snapshot
make restore AZ=c SNAPSHOT=none                     # fresh server, then run CD
```

[staging/restore.sh](staging/restore.sh) builds an image from the snapshot, replaces the server in the chosen AZ with `terraform apply -replace` (it asks for `yes`), and removes the old K3s node. The Elastic IP, ALB target and idle alarm follow the new instance.

> **Note:** the shop databases (carts-db, orders-db, user-db, session-db) use `emptyDir` volumes, so their data is lost whenever a pod is recreated, including after a restore. Snapshots protect the node (K3s, cached images, config), not shop data.

## Checking and fixing the deployment

```bash
./check-deployment-status.sh   # instance state, ALB target health, app URL, pods
./fix-deployment.sh            # redeploy this checkout the same way CD does
```

`fix-deployment.sh` deploys whatever is in your working tree without CI, so use it only to recover a broken staging. Normally a push to `staging` deploys after CI passes.

## Running locally without AWS

```bash
cd deploy/docker-compose
docker compose up -d     # start; the shop is at http://localhost
docker compose down      # stop
```

Add `-f docker-compose.monitoring.yml` to also run Prometheus and Grafana.

## Cost

| State | Still billed | Per month (approx.) |
|---|---|---|
| Running 24/7 | EC2 + ALB + disk + public IP + snapshots | $60–70 |
| Stopped | ALB (~$20) + 50 GB disk (~$5) + Elastic IP (~$4) + snapshots (~$2) | ~$30 |
| Destroyed (`terraform destroy`) | Route 53 zone + S3 state | ~$1 |

Stop/start is used instead of destroy because a stopped instance is back in about 2 minutes with the same instance, Elastic IP and load balancer. Re-creating takes 15+ minutes (new ALB, certificate validation, K3s install, image pulls). For long breaks, `terraform destroy` is cheaper, and one `terraform apply` or CD run brings it back.

## What's in the cluster

| Group | Components |
|---|---|
| Services (8) | front-end, catalogue, carts, orders, payment, shipping, user, queue-master |
| Data stores (5) | carts-db, orders-db, user-db (MongoDB), catalogue-db (MySQL), session-db (Redis) |
| Messaging | RabbitMQ, with an exporter sidecar |
| Monitoring | Prometheus, Grafana, kube-state-metrics, node-exporter |

## Upstream

The application itself comes from [microservices-demo](https://github.com/microservices-demo/microservices-demo) (built with Spring Boot, Go kit and Node.js), which is no longer maintained. Its application design is described in [internal-docs/design.md](internal-docs/design.md), and the other deployment targets it supported are in [deploy/](deploy/).
