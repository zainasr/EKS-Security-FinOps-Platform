variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version — pinned one behind latest"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from vpc module output"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs — nodes live here, from vpc module output"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR — used in security group rules for node communication"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

variable "console_access_arn" {
  description = "IAM ARN of the AWS Console user/role for EKS dashboard access"
  type        = string
  default = "arn:aws:iam::498259426922:root"
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL without https://"
  type        = string
}
