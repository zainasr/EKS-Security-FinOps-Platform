output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "API server endpoint — used by kubectl and Helm provider"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64 CA certificate — validates API server identity"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true  # Never printed in logs
}

output "cluster_oidc_issuer_url" {
  description = "OIDC URL — Karpenter and IRSA use this for pod IAM roles"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "ebs_csi_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}


output "node_role_arn" {
  description = "Node IAM role ARN — Karpenter module needs this"
  value       = aws_iam_role.eks_nodes.arn
}

output "node_security_group_id" {
  description = "Node SG ID — Karpenter attaches this to provisioned nodes"
  value       = aws_security_group.nodes.id
}

output "cluster_version" {
  description = "Running K8s version — verify matches pinned version"
  value       = aws_eks_cluster.main.version
}