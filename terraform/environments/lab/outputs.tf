output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint — used by kubectl and Helm provider"
  value       = module.eks.cluster_endpoint
}

output "karpenter_controller_role_arn" {
  description = "IAM role ARN for Karpenter controller pod — used in Helm values"
  value       = module.karpenter.controller_role_arn
}

output "karpenter_interruption_queue_name" {
    value = module.karpenter.karpenter_interruption_queue_name
}




