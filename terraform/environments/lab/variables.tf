variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks-security-lab"
}

variable "kubernetes_version" {
  description = "Kubernetes version - pinned, never latest"
  type        = string
  default     = "1.31"
}