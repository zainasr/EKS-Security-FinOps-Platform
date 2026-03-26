
resource "aws_kms_key" "eks_secrets" {
  description             = "KMS key for EKS secrets encryption - ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true # Rotate annually, automatic, free

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-secrets-key"
  })
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}



resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-control-plane-logs"
  })
}


resource "aws_eks_cluster" "main" {
  name    = var.cluster_name
  version = var.kubernetes_version

  role_arn = aws_iam_role.eks_cluster.arn

  enabled_cluster_log_types = ["api", "audit", "scheduler"]

  vpc_config {
    subnet_ids = var.private_subnet_ids

    security_group_ids = [aws_security_group.cluster_additional.id]

    
    endpoint_private_access = true

   
    endpoint_public_access = true

  
    public_access_cidrs = ["0.0.0.0/0"]
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

 
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false 
  }

 
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_cloudwatch_log_group.eks
  ]

  tags = merge(var.tags, {
    Name = var.cluster_name
  })
}


data "aws_caller_identity" "current" {}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/eks"
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster" # cluster-wide, not namespace-scoped
  }
}

resource "aws_eks_access_entry" "console" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.console_access_arn  # new variable
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "console" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.console.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}


resource "aws_eks_access_entry" "nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.eks_nodes.arn

  # EC2_LINUX type = worker node identity
  # Automatically maps to system:nodes group in K8s RBAC
  # No policy association needed — type handles it
  type = "EC2_LINUX"

  tags = var.tags
}




resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc-cni"
  })

  depends_on = [aws_eks_cluster.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-coredns"
  })

  depends_on = [aws_eks_cluster.main]
}


resource "aws_eks_addon" "kube_proxy" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-kube-proxy"
  })

  depends_on = [aws_eks_cluster.main]
}



# ─────────────────────────────────────────────
# BOOTSTRAP NODE GROUP
# ─────────────────────────────────────────────
# Why this exists:
#   Karpenter + CoreDNS + Cilium need somewhere to run
#   before Karpenter can provision nodes for them
#   This small fixed group breaks the chicken-and-egg
#
# Production pattern:
#   2 x t3.medium = enough for all system components
#   Karpenter manages ALL application workload nodes
#   This group never scales — fixed at 2
#
# Taint: CriticalAddonsOnly
#   Prevents application pods scheduling here
#   Only pods that tolerate this taint can run here
#   Keeps system components isolated from workloads
resource "aws_eks_node_group" "bootstrap" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-bootstrap"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids

  # Fixed size — never scales
  # min=2 ensures system components always have capacity
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  instance_types = ["t3.medium"]

  # Taint: only system pods allowed here
  # effect NoSchedule = pods without toleration never land here
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  # AL2 is the EKS-optimized AMI family
  # AWS manages patching
  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  disk_size      = 20

  # Karpenter should not manage these nodes
  # This label tells Karpenter: ignore this node group
  labels = {
    "karpenter.sh/controller" = "false"
    "node-type"               = "bootstrap"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-bootstrap-node"
    # Explicitly exclude from Karpenter discovery
    "karpenter.sh/discovery" = "excluded"
  })

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_policy,
  ]
}


resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [
    aws_eks_node_group.bootstrap
  ]
}
