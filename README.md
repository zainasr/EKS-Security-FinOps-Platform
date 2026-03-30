# EKS Security + FinOps Platform

Production-grade Kubernetes cost and security governance platform on AWS EKS. Implements defense-in-depth security with real-time cost attribution, using only open-source CNCF tools.

## Stack

| Component | Version | Role |
|-----------|---------|------|
| EKS | 1.31 | Managed Kubernetes control plane |
| Karpenter | 1.1.0 | Node autoscaling and cost optimization |
| Cilium | 1.18.6 | eBPF CNI, network policy, Hubble observability |
| OPA/Gatekeeper | 3.18.0 | Admission control, policy enforcement |
| Falco | 0.42.1 | Runtime security, syscall monitoring |
| Kubecost | 2.8.6 | Cost allocation per namespace, team, workload |
| Terraform | 1.14+ | Infrastructure as code |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  AWS Account (us-east-1)                                │
│                                                         │
│  VPC 10.0.0.0/16                                       │
│  ├── Public subnets (2 AZs)  ← NAT Gateway, ALB       │
│  └── Private subnets (2 AZs) ← All EKS nodes           │
│                                                         │
│  EKS Cluster (1.31)                                     │
│  ├── Bootstrap nodes (2x t3.medium, fixed)              │
│  │   ├── Karpenter controller                           │
│  │   ├── Gatekeeper (OPA)                               │
│  │   ├── Kubecost                                       │
│  │   └── Falco (DaemonSet, all nodes)                   │
│  │                                                      │
│  └── Karpenter nodes (dynamic, on-demand t3.medium/large)│
│      ├── team-frontend namespace                         │
│      ├── team-backend namespace                          │
│      └── team-data namespace                             │
│                                                         │
│  VPC Endpoints: S3, STS, EC2 (no NAT for AWS APIs)     │
└─────────────────────────────────────────────────────────┘
```

## Security Layers

| Layer | Tool | What It Catches |
|-------|------|----------------|
| Admission | Gatekeeper | No resource limits, latest image tags, privileged containers, missing labels |
| Network | Cilium | L7-aware network policies, east-west traffic control |
| Runtime | Falco | Shell spawned in container, credential theft, crypto mining, suspicious syscalls |
| Infrastructure | Terraform + IAM | Least-privilege IRSA, KMS encryption, private endpoints |

## FinOps

Kubecost provides per-namespace cost allocation via namespace labels (`team`, `cost-center`). Three team namespaces (`team-frontend`, `team-backend`, `team-data`) demonstrate multi-tenant cost attribution with per-namespace `ResourceQuota` and `LimitRange` enforcement.

## Prerequisites

- AWS CLI configured with an IAM user (least-privilege policy)
- aws-vault for credential management
- Terraform 1.10+
- kubectl, helm 3.9+

## Deploy

```bash
# Clone
git clone https://github.com/<you>/eks-security-finops-lab
cd eks-security-finops-lab

# Bootstrap S3 backend (one-time)
aws s3api create-bucket --bucket <your-state-bucket> --region us-east-1

# Deploy infrastructure
cd terraform/environments/lab
terraform init
aws-vault exec --no-session <profile> -- terraform apply

# Configure kubectl
aws eks update-kubeconfig --name eks-security-lab --region us-east-1

# Install platform components (in order)
helm install karpenter oci://public.ecr.aws/karpenter/karpenter ...
helm install cilium cilium/cilium ...
helm install gatekeeper gatekeeper/gatekeeper ...
helm install falco falcosecurity/falco ...
helm install kubecost oci://public.ecr.aws/kubecost/cost-analyzer ...

# Apply policies and workloads
kubectl apply -f manifests/namespaces/
kubectl apply -f manifests/gatekeeper/templates/
kubectl apply -f manifests/gatekeeper/constraints/
kubectl apply -f manifests/team-frontend/
kubectl apply -f manifests/team-backend/
kubectl apply -f manifests/team-data/
```

## Repository Structure

```
.
├── terraform/
│   ├── environments/
│   │   └── lab/
│   │       ├── backend.tf          # S3 state, native locking
│   │       ├── main.tf             # Module composition
│   │       ├── variables.tf
│   │       └── terraform.tfvars
│   └── modules/
│       ├── vpc/                    # VPC, subnets, NAT, VPC endpoints
│       ├── eks/                    # EKS cluster, addons, IRSA roles, SGs
│       └── karpenter/              # Karpenter IAM, SQS, OIDC, EC2NodeClass
├── manifests/
│   ├── namespaces/                 # Namespaces, ResourceQuota, LimitRange
│   ├── gatekeeper/
│   │   ├── templates/              # ConstraintTemplates (Rego policies)
│   │   └── constraints/            # Constraint instances
│   ├── falco/                      # Custom Falco rules ConfigMap
│   ├── team-frontend/              # Sample workload (intentional violations)
│   ├── team-backend/               # Sample workload (intentional violations)
│   └── team-data/                  # Sample workload (intentional violations)
└── docs/
    ├── kubecost.md                 # Kubecost install guide
    ├── architecture-decisions.md   # ADRs
    └── runbook.md                  # Operational procedures
```

## Key Design Decisions

**Karpenter over Cluster Autoscaler** — Karpenter provisions nodes directly via EC2 API, enabling bin-packing, spot support, and node consolidation. Cluster Autoscaler only scales node groups.

**Cilium chained mode** — VPC CNI handles ENI IP allocation (native AWS routing, no overlay overhead). Cilium adds eBPF network policy and Hubble observability on top without replacing IP management.

**Gatekeeper with hostNetwork** — Gatekeeper's audit controller watches Gatekeeper-owned API groups (status.gatekeeper.sh, config.gatekeeper.sh) which are served by Gatekeeper itself. Without hostNetwork, the watch loop causes a circular timeout via pod networking. hostNetwork bypasses Cilium and reaches the API server via the node's primary SG directly.

**VPC endpoints for STS and EC2** — IRSA requires pods to call `sts.amazonaws.com` to exchange projected service account tokens. Private subnets without a public route to STS cause IRSA timeouts. Interface VPC endpoints resolve STS and EC2 API calls within the VPC without traversing the NAT gateway.

**Bootstrap node group** — A fixed two-node managed group hosts all control-plane-touching system components (Karpenter, Gatekeeper, Kubecost). These nodes are tainted `CriticalAddonsOnly` and labeled `node-type=bootstrap`. Application workloads run on dynamically provisioned Karpenter nodes, maintaining clear separation between system and application compute.

## Accessing Dashboards

```bash
# Kubecost — cost allocation
kubectl port-forward -n kubecost deployment/kubecost-cost-analyzer 9090
# http://localhost:9090

# Hubble UI — network flows
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# http://localhost:12000

# Falco alerts — live stream
kubectl logs -n falco -l app.kubernetes.io/name=falco -f
```

## License

MIT 