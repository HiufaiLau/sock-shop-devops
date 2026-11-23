# Troubleshooting Guide - Sock Shop Not Accessible

## Before you start: which AWS account

Staging runs in AWS account **414772274298**, region **eu-central-1**. Use the
AWS CLI profile for that account (named `sockshop` here; other profiles such as
`terraform_user` point at a different account and get `AccessDenied`).

```bash
export AWS_PROFILE=sockshop AWS_REGION=eu-central-1
aws sts get-caller-identity          # Account must be 414772274298

# The instance ID changes when Terraform replaces the server; look it up:
INSTANCE_ID=$(staging/find-instance.sh)
```

The instance has no open ports (no SSH, no public NodePorts). Everything goes
through the ALB (https://sockshop-staging.link) or AWS SSM. It is also stopped
automatically after 30 min idle: `make status` / `make up`.

## 🚨 Critical Issues to Fix First

### 1. System Clock Issue (MUST FIX FIRST!)

**Problem**: AWS commands fail with "Signature expired" error
**Cause**: Your Mac's system clock is incorrect (showing future dates)

**Fix**:
```bash
# Option 1: Command line
sudo sntp -sS time.apple.com

# Option 2: System Settings
# Go to: System Settings → General → Date & Time
# Turn ON "Set time and date automatically"
```

**Verify**:
```bash
date
# Should show current date/time, not future dates
```

---

## 🔍 Why the Application Isn't Working

### Current Status
- ❌ **App URL**: https://sockshop-staging.link (via the ALB)
- **Error**: 502/503/504 from the ALB
- (There is no direct URL: NodePort 30080 only accepts traffic from the ALB.)

### Root Causes

**The application isn't working because:**

1. **The instance is stopped or K3s is still starting**
   - The idle alarm stops the instance after 30 min (`make status`, `make up`)
   - On first boot, user-data installs K3s (3-5 minutes)

2. **Sock Shop pods haven't started**
   - 14 microservices need to download images
   - Each pod needs to start and pass health checks
   - Takes 5-10 minutes after K3s is ready

3. **No service listening on port 30080**
   - The Sock Shop `front-end` service uses NodePort 30080
   - ALB routes to this port
   - Port only responds when front-end pod is running

---

## ✅ Step-by-Step Fix

### Step 1: Fix Your System Clock (DO THIS FIRST!)

```bash
sudo sntp -sS time.apple.com
date  # Verify it shows correct time
```

### Step 2: Check if K3s is Running

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["systemctl is-active k3s"]' \
  --region eu-central-1 \
  --query "Command.CommandId" \
  --output text
```

Wait 5 seconds, then get the result with the command ID returned above.

**Expected output**: `active`

### Step 3: Check User-Data Log

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["tail -50 /var/log/user-data.log"]' \
  --region eu-central-1 \
  --query "Command.CommandId" \
  --output text
```

**Look for**: "K3s installation complete!"

### Step 4: Deploy Sock Shop (If Not Already Deployed)

Don't apply the upstream manifest by hand. Redeploy this repo's manifests the
way CD does (Actions → **CD (Deploy)** → Run workflow), or from your checkout:

```bash
./fix-deployment.sh
```

### Step 5: Wait for Pods to Start (10-15 minutes)

Check pod status:
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["kubectl get pods -n sock-shop"]' \
  --region eu-central-1 \
  --query "Command.CommandId" \
  --output text
```

**What you want to see**:
```
NAME                       READY   STATUS    RESTARTS   AGE
front-end-xxx              1/1     Running   0          5m
carts-xxx                  1/1     Running   0          5m
...all pods Running...
```

### Step 6: Test Direct Connection

Port 30080 is not reachable from your laptop; test it on the node via SSM:

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["curl -sS -o /dev/null -w %{http_code} http://127.0.0.1:30080/"]' \
  --query "Command.CommandId" \
  --output text
```

**Expected**: HTML response (Sock Shop homepage)

### Step 7: Check ALB Target Health

```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --names sockshop-staging-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN"
```

**Expected**: `"State": "healthy"`

---

## 🔧 Shell on the Node (SSM Session Manager)

SSH and EC2 Instance Connect don't work (port 22 is closed). Use SSM, which
needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html):

```bash
aws ssm start-session --target "$INSTANCE_ID"
sudo kubectl get pods -A
sudo kubectl -n sock-shop get pods -w
```

Or in the console: EC2 → Instances → **sockshop-staging-k3s-server** →
Connect → **Session Manager**.

---

## 📊 Expected Timeline

| Time | Status | What's Happening |
|------|--------|------------------|
| **0 min** | Instance started | K3s starting |
| **3-5 min** | K3s ready | Can deploy apps |
| **5-10 min** | Pods starting | Downloading images |
| **10-15 min** | ✅ Working | App accessible |

---

## 🐛 Common Issues

### Issue: "Signature expired" Error
**Cause**: System clock is wrong
**Fix**: `sudo sntp -sS time.apple.com`

### Issue: Pods stuck in "Pending"
**Cause**: Insufficient resources
**Fix**: The node is a t3.medium (4 GiB) running the shop and monitoring. Check
`kubectl describe node` (Allocated resources); if memory is the limit, set
`master_instance_type = "t3.large"`

### Issue: Pods stuck in "ImagePullBackOff"
**Cause**: Can't download Docker images
**Check**: Internet connectivity from instance

### Issue: Pods "CrashLoopBackOff"
**Cause**: Application errors, dependency issues
**Fix**: Check specific pod logs:
```bash
kubectl logs <pod-name> -n sock-shop
```

### Issue: Target always "unhealthy"
**Possible causes**:
1. Front-end pod not running
2. Service not created correctly
3. Security group not allowing 30080 from the ALB security group
4. Health check path incorrect

**Check service**:
```bash
kubectl get svc -n sock-shop front-end
# Should show NodePort: 30080
```

---

## 🆘 Nuclear Option: Redeploy Everything

If nothing works after 30 minutes:

```bash
cd sock-shop-devops/staging

# Destroy and recreate
terraform destroy -auto-approve
terraform apply -auto-approve
```

**Warning**: This will:
- Delete the instance
- Create a new one
- Start from scratch
- Take 15-20 minutes total

---

## 📱 Quick Status Check Script

Run (uses the `sockshop` profile by default):

```bash
cd sock-shop-devops
./check-deployment-status.sh
```

This checks:
- ✅ Target health
- ✅ HTTP response codes
- ✅ Pod status

---

## 🎯 Success Criteria

You'll know it's working when:

1. ✅ `curl https://sockshop-staging.link` returns HTML
2. ✅ Target health shows "healthy"
3. ✅ Browser shows Sock Shop homepage at https://sockshop-staging.link
4. ✅ All 14 pods show "Running" status

---

## 📞 Need Help?

If stuck after trying everything:

1. Check the GitHub Actions logs (if workflow ran)
2. Review instance user-data logs
3. Check CloudWatch logs (if configured)
4. Post issue with:
   - Output of `./check-deployment-status.sh`
   - Pod status
   - Target health status

---

## 🔗 Useful Links

- **EC2 Console**: https://eu-central-1.console.aws.amazon.com/ec2/home?region=eu-central-1#Instances:
- **Load Balancers**: https://eu-central-1.console.aws.amazon.com/ec2/home?region=eu-central-1#LoadBalancers:
- **GitHub Actions**: https://github.com/HiufaiLau/sock-shop-devops/actions
- **Sock Shop Docs**: https://microservices-demo.github.io/

---

