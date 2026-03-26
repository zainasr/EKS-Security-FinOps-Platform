variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API server endpoint — Karpenter needs this to register nodes"
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL — used to federate K8s service account with IAM"
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for worker nodes — already created in EKS module"
  type        = string
}

variable "node_security_group_id" {
  description = "Security group ID for nodes — Karpenter attaches to new EC2s"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs — Karpenter launches nodes here only"
  type        = list(string)
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}