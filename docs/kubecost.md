# Kubecost — EKS Cost Monitoring

## Overview

Kubecost provides real-time cost allocation for Kubernetes resources broken down by namespace, pod, label, and team. On EKS, AWS and Kubecost maintain an optimised bundle available at no additional charge via Amazon ECR Public Gallery.

## Architecture

```
Kubecost components (all in kubecost namespace):
  cost-analyzer     ← frontend + cost model backend
  prometheus-server ← scrapes cluster metrics, stores time-series
  kube-state-metrics← Kubernetes object metrics (pods, nodes, PVCs)

Data flow:
  Node metrics → kube-state-metrics → Prometheus → cost-analyzer
  AWS pricing API (public) → cost-analyzer (no key required)
  Team labels (team, cost-center) → cost allocation grouping
```

## Prerequisites

### 1. EBS CSI Driver with IRSA

EKS 1.23+ requires the EBS CSI driver for dynamic PV provisioning. The driver needs IRSA to call EC2 APIs.

```hcl
# terraform/modules/eks/iam.tf
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn
}
```

Trust policy scoped to `system:serviceaccount:kube-system:ebs-csi-controller-sa`.

### 2. VPC Endpoints for STS and EC2

IRSA requires pods to call `sts.amazonaws.com` to exchange projected tokens. Nodes in private subnets without a direct internet route need interface VPC endpoints.

```hcl
# terraform/modules/vpc/main.tf
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
}

resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.ec2"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
}
```

### 3. gp3 StorageClass

EKS 1.30+ has no default StorageClass. The in-tree `gp2` provisioner (`kubernetes.io/aws-ebs`) is deprecated. Use the EBS CSI driver with `gp3`.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
```

### 4. Gatekeeper Namespace Exemption

If OPA/Gatekeeper is installed, its admission webhook intercepts namespace creation. Exempt `kubecost` via the Config resource before installing.

```yaml
apiVersion: config.gatekeeper.sh/v1alpha1
kind: Config
metadata:
  name: config
  namespace: gatekeeper-system
spec:
  match:
    - excludedNamespaces:
        - gatekeeper-system
        - kube-system
        - karpenter
        - falco
        - kubecost
      processes: ["*"]
```

Create the namespace manually before Helm runs:

```bash
kubectl create namespace kubecost
```

## Installation

Use the official AWS ECR OCI registry combined with the official EKS values file. Do not use the `kubecost/cost-analyzer` Helm repo (contains migration-only versions).

```bash
# Custom overrides — saved to /tmp/kubecost-custom.yaml
cat > /tmp/kubecost-custom.yaml << 'EOF'
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
    effect: NoSchedule

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-type
              operator: In
              values: [bootstrap]

persistentVolume:
  storageClass: gp3

prometheus:
  server:
    persistentVolume:
      storageClass: gp3
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
        effect: NoSchedule
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-type
                  operator: In
                  values: [bootstrap]
EOF

helm upgrade --install kubecost \
  oci://public.ecr.aws/kubecost/cost-analyzer \
  --version 2.8.6 \
  --namespace kubecost \
  -f https://raw.githubusercontent.com/kubecost/cost-analyzer-helm-chart/develop/cost-analyzer/values-eks-cost-monitoring.yaml \
  -f /tmp/kubecost-custom.yaml \
  --wait --timeout=300s
```

The official EKS values file configures AWS-specific settings. Our overrides layer on top to pin to bootstrap nodes and use gp3.

## Verification

```bash
# All pods running
kubectl get pods -n kubecost -o wide

# PVCs bound to gp3 volumes
kubectl get pvc -n kubecost

# Access dashboard
kubectl port-forward -n kubecost deployment/kubecost-cost-analyzer 9090
# Open http://localhost:9090
```

## Cost Attribution

Kubecost uses pod labels for cost grouping. Each team namespace has mandatory labels enforced by Gatekeeper:

```yaml
# Required labels (enforced by K8sRequiredLabels constraint)
labels:
  team: frontend        # maps to Kubecost namespace grouping
  cost-center: cc-001   # maps to Kubecost label grouping
  app: frontend-app
```

In the Kubecost UI: Allocations → Group by Namespace → shows `team-frontend`, `team-backend`, `team-data` with daily cost breakdown.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| PVC stays Pending | No default StorageClass or wrong provisioner | Create gp3 StorageClass with `ebs.csi.aws.com` provisioner |
| EBS CSI controller CrashLoopBackOff | IRSA can't reach STS | Add STS VPC endpoint, restart controller |
| Helm install fails with 409 on namespace | Gatekeeper webhook blocking | Exempt kubecost in Gatekeeper Config resource |
| cost-analyzer pod 0/2 | Prometheus not ready yet | Wait 2-3 minutes, Prometheus initialises first |
| No cost data after install | Kubecost needs 15+ min to collect metrics | Wait, then check Allocations tab |

## Version Notes

| Version | Notes |
|---------|-------|
| 2.8.6 | Stable, recommended for single-cluster EKS |
| 2.9.x | Migration-only bridge to v3, not for new installs |
| 3.x | ClickHouse backend, S3 required for multi-cluster, different Helm chart location |