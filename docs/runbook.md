# Operational Runbook

## Day-to-Day Operations

### Check Cluster Health

```bash
# Nodes
kubectl get nodes -o wide

# System pods
kubectl get pods -n kube-system
kubectl get pods -n karpenter
kubectl get pods -n gatekeeper-system
kubectl get pods -n falco
kubectl get pods -n kubecost

# Karpenter node provisioning activity
kubectl get nodeclaims
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --since=1h | grep -E "launched|terminated|consolidated"
```

### Access Dashboards

```bash
# Kubecost — cost by namespace, team, workload
kubectl port-forward -n kubecost deployment/kubecost-cost-analyzer 9090
# http://localhost:9090

# Hubble UI — real-time pod network flows
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# http://localhost:12000

# Falco alerts — last 5 minutes
kubectl logs -n falco -l app.kubernetes.io/name=falco --since=5m | python3 -m json.tool | grep -E "rule|priority|output"
```

---

## Security Alerts

### Falco: Shell Spawned in Container

**Alert:** `Terminal shell in container`
**Priority:** WARNING

Indicates an interactive shell was opened in a running container. Legitimate applications do not need shells at runtime.

**Investigation:**
```bash
# Identify which pod
# The alert output includes: pod name, namespace, user, parent process

# Check if kubectl exec was used (check audit logs or CloudTrail)
# Check if the pod has been compromised

# Immediate containment if confirmed malicious
kubectl delete pod <pod-name> -n <namespace>

# Review pod's ServiceAccount permissions
kubectl get rolebinding,clusterrolebinding -A | grep <pod-serviceaccount>
```

---

### Falco: Service Account Token Read

**Alert:** `Service account token read`
**Priority:** CRITICAL

A process read `/var/run/secrets/kubernetes.io/serviceaccount/token`. This token authenticates to the Kubernetes API. Theft enables privilege escalation.

**Investigation:**
```bash
# Check what the ServiceAccount can do
kubectl auth can-i --list --as=system:serviceaccount:<namespace>:<sa-name>

# Rotate the token immediately
kubectl delete secret -n <namespace> <sa-token-secret>
# Kubernetes auto-creates a new token

# If broad permissions, restrict the ServiceAccount RBAC
```

---

### Gatekeeper: Policy Violation

**Check current violations:**
```bash
kubectl get k8srequireresourcelimits,k8snolatesttag,k8snoprivileged,k8srequirenonroot,k8srequiredlabels \
  -o custom-columns='POLICY:.metadata.name,VIOLATIONS:.status.totalViolations'
```

**View specific violating resources:**
```bash
kubectl describe k8snolatesttag no-latest-tag | grep -A5 "Violations"
```

**Fix a violation (example — add resource limits):**
```bash
kubectl patch deployment <name> -n <namespace> --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"100m","memory":"128Mi"},"limits":{"cpu":"500m","memory":"512Mi"}}}]'
```

---

## FinOps Procedures

### View Cost by Namespace

```bash
# Via Kubecost API
kubectl exec -n kubecost \
  $(kubectl get pod -n kubecost -l app=cost-analyzer -o name | head -1) \
  -- curl -s "http://localhost:9001/model/allocation?window=7d&aggregate=namespace" \
  | python3 -m json.tool | grep -E '"name"|totalCost'
```

In Kubecost UI: Allocations → Group by: Namespace → Window: Last 7 days

### Check Namespace Quota Usage

```bash
kubectl describe resourcequota -n team-frontend
kubectl describe resourcequota -n team-backend
kubectl describe resourcequota -n team-data
```

### Karpenter Cost Optimisation

```bash
# Check consolidation candidates
kubectl get nodeclaims -o wide

# Force consolidation now (disrupts pods — use in maintenance window)
kubectl annotate nodepool default karpenter.sh/do-not-disrupt-

# Check spot interruption queue
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url --queue-name eks-security-lab-karpenter --query QueueUrl --output text) \
  --attribute-names ApproximateNumberOfMessages
```

---

## Maintenance

### Upgrade Karpenter

```bash
# 1. Check release notes for breaking changes
# 2. Update version in helm upgrade command
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter --version <new-version> \
  --values <existing-values>

# 3. Update NodePool/EC2NodeClass API version if required
```

### Rotate Node Group (Bootstrap Nodes)

```bash
# Cordon one bootstrap node
kubectl cordon <node>

# Drain (respect PodDisruptionBudgets)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --grace-period=120

# Terminate EC2 instance — ASG replaces it
aws ec2 terminate-instances --instance-ids <instance-id>

# Verify replacement joins and is labeled
kubectl get nodes -l node-type=bootstrap -w
```

### Terraform Apply (Infrastructure Changes)

```bash
# Always plan first
aws-vault exec --no-session <profile> -- \
  terraform -chdir=terraform/environments/lab plan

# Apply targeting a specific module
aws-vault exec --no-session <profile> -- \
  terraform -chdir=terraform/environments/lab \
  apply -target=module.vpc

# Full apply
aws-vault exec --no-session <profile> -- \
  terraform -chdir=terraform/environments/lab apply
```

---

## Disaster Recovery

### Cluster Unreachable

1. Check EKS control plane status in AWS Console → EKS → Clusters
2. Check bootstrap node health in EC2 console (nodes with `node-type=bootstrap` tag)
3. If nodes unhealthy, terminate them — ASG replaces automatically
4. After node replacement, system pods reschedule within 2-3 minutes

### Karpenter Not Provisioning Nodes

```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --since=10m | grep -E "ERROR|error"

# Check NodePool status
kubectl describe nodepool default

# Verify EC2 quotas not hit
aws ec2 describe-account-attributes --attribute-names max-instances
```

### PVC Stuck in Pending

```bash
# Check events
kubectl describe pvc <name> -n <namespace>

# Verify EBS CSI controller is healthy (6/6 containers)
kubectl get pods -n kube-system -l app=ebs-csi-controller

# Verify StorageClass exists
kubectl get storageclass gp3

# Verify VPC endpoints are available
aws ec2 describe-vpc-endpoints --filters "Name=service-name,Values=com.amazonaws.us-east-1.sts" \
  --query 'VpcEndpoints[0].State'
