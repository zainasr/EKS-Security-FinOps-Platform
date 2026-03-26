output "controller_role_arn" {
  description = "IAM role ARN for Karpenter controller pod — used in Helm values"
  value       = aws_iam_role.karpenter_controller.arn
}

output "node_instance_profile_name" {
  description = "Instance profile name — EC2NodeClass references this"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "interruption_queue_name" {
  description = "SQS queue name — Karpenter Helm chart config needs this"
  value       = aws_sqs_queue.karpenter.name
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — needed for any future IRSA roles"
  value       = aws_iam_openid_connect_provider.eks.arn
}
output "oidc_provider_url" {
  description = "OIDC provider URL without https:// for IRSA conditions"
  value       = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}
output "karpenter_interruption_queue_name" {
    description = "queue-name"
    value = aws_sqs_queue.karpenter.name
}