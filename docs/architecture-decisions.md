# Architecture Decision Records

## ADR-001: Karpenter over Cluster Autoscaler

**Decision:** Use Karpenter 1.1.0 for node autoscaling.

**Context:** EKS supports both Cluster Autoscaler (CA) and Karpenter. CA scales existing managed node groups. Karpenter provisions individual EC2 instances directly.

**Rationale:**
- Karpenter provisions nodes in seconds by calling EC2 API directly; CA waits for node group scaling events (minutes)
- Karpenter performs bin-packing across instance types and AZs; CA is limited to the instance types defined in the node group
- Karpenter's consolidation feature terminates underutilised nodes automatically; CA only scales down after idle periods
- NodePool and EC2NodeClass CRDs give platform teams per-workload control over instance families, capacity types, and node expiry

**Trade-off:** Karpenter requires IRSA with broad EC2 permissions and an SQS queue for spot interruption handling. More complex initial setup than CA but significantly more capable operationally.

---

## ADR-002: Cilium Chained Mode over Replacing VPC CNI

**Decision:** Use Cilium in ENI chained mode (VPC CNI handles IPs, Cilium handles policy and observability).

**Context:** Cilium can run in two modes on EKS: replacing VPC CNI entirely (kube-proxy-free), or chaining on top of VPC CNI.

**Rationale:**
- Chained mode preserves native VPC routing — pods get real ENI IPs, no overlay encapsulation, compatible with Security Groups for Pods and VPC Flow Logs
- Full replacement mode requires careful migration and disabling kube-proxy, increasing operational risk
- Hubble observability works identically in both modes
- L7 network policies (HTTP method + path aware) are available in both modes

**Trade-off:** Some eBPF performance gains (socket-level load balancing, kube-proxy bypass) are not realised in chained mode. For this project's scale these are immaterial.

---

## ADR-003: Gatekeeper over Kyverno

**Decision:** Use OPA/Gatekeeper 3.18.0 for admission control.

**Context:** Both Gatekeeper and Kyverno are CNCF-graduated admission controllers. Kyverno uses a YAML-native policy language; Gatekeeper uses Rego.

**Rationale:**
- Rego is a general-purpose policy language used across Terraform (Sentinel), Envoy, and other infrastructure tools — learning it transfers broadly
- Gatekeeper's audit mode retroactively reports violations on existing resources without blocking them, enabling gradual enforcement rollout
- OPA is the CNCF policy standard; Gatekeeper is its Kubernetes wrapper

**Trade-off:** Rego has a steeper learning curve than Kyverno's YAML policies. Gatekeeper's admission webhook requires `hostNetwork: true` when running alongside Cilium due to a circular watch dependency on its own aggregated API groups — this is a known pattern for system components that call the Kubernetes API.

---

## ADR-004: Bootstrap Node Group for System Components

**Decision:** Maintain a fixed two-node managed node group tainted `CriticalAddonsOnly` to host all control-plane-touching system components.

**Context:** Karpenter provisions application nodes dynamically. All system components could run on Karpenter nodes.

**Rationale:**
- System components (Karpenter, Gatekeeper, Kubecost, Falco) call the Kubernetes API server. The network path from Karpenter-provisioned nodes through Cilium to the API server has edge cases with Gatekeeper's aggregated API groups and IRSA token exchange
- Bootstrap nodes use the EKS primary security group (auto-created by EKS) which has a self-referencing rule allowing full communication with the control plane
- Karpenter cannot manage its own nodes — if Karpenter runs on a Karpenter node and that node is consolidated, Karpenter terminates itself
- Fixed two-node group provides predictable capacity and cost for system components

**Trade-off:** Two always-on t3.medium nodes add ~$60/month. This is the correct trade-off for operational stability.

---

## ADR-005: VPC Endpoints for STS and EC2

**Decision:** Use Interface VPC Endpoints for `sts.amazonaws.com` and `ec2.amazonaws.com`.

**Context:** IRSA requires pods to POST to `sts.amazonaws.com` to exchange projected service account tokens for AWS credentials. EBS CSI driver calls the EC2 API to create and attach volumes.

**Rationale:**
- Private subnets route internet-bound traffic through a NAT Gateway. NAT Gateway adds latency and cost to AWS API calls
- Interface VPC endpoints route AWS API calls within the VPC, bypassing NAT entirely
- Without STS endpoint, IRSA fails with `dial tcp: lookup sts.us-east-1.amazonaws.com: i/o timeout` on nodes without internet access
- STS and EC2 endpoints are prerequisites for EBS CSI driver and all IRSA-enabled components

**Cost:** Interface endpoints cost ~$7/month each (us-east-1). S3 Gateway endpoint is free and saves NAT costs for ECR image pulls.

---

## ADR-006: Falco with Modern eBPF Driver

**Decision:** Use Falco 0.42.1 with `driver.kind: modern_ebpf` instead of kernel module.

**Context:** Falco supports three drivers: kernel module (kmod), classic eBPF probe, and modern eBPF probe.

**Rationale:**
- Kernel module requires compiling against the specific kernel version on each node. EKS nodes run Amazon Linux 2 with kernel 5.10; the module must match exactly and breaks on kernel updates
- Modern eBPF requires kernel 5.8+ (EKS 1.31 nodes run 5.10, satisfying this)
- Modern eBPF loads safely via the kernel's BPF verifier — cannot crash the node
- No recompilation needed on kernel updates

**Trade-off:** Cilium also uses eBPF. Both Cilium and Falco load separate eBPF programs; they do not conflict because they attach to different hook points (Cilium: TC/socket, Falco: tracepoints/kprobes).

---

## ADR-007: Kubecost v2 over v3

**Decision:** Use Kubecost 2.8.6 (v2) for cost monitoring.

**Context:** Kubecost v3 was released in 2025 with a major architectural change: ClickHouse database replaces DuckDB/Prometheus, and multi-cluster requires S3 storage.

**Rationale:**
- Single-cluster deployment does not require S3 or ClickHouse
- v2 uses bundled Prometheus (included in the Helm chart) requiring no additional infrastructure
- v3 migration requires careful planning and impacts report availability during transition
- 2.8.6 is the latest stable v2 release — v2.9.x is a migration-only bridge to v3, not recommended for new installs
- AWS EKS optimised bundle for v2 is available at no additional charge via ECR

**Upgrade path:** When v3 stabilises, migration uses `helm upgrade` with the new chart location (`public.ecr.aws/kubecost/kubecost`) and a new values file structure.