# These outputs are consumed by the EKS module
# Good output design: expose everything the next layer needs
# so it never has to reach back into the VPC module internals

output "vpc_id" {
  description = "VPC ID — consumed by EKS cluster + security groups"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block — used in security group rules"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs — for load balancers"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs — EKS nodes + Karpenter discovery"
  value       = aws_subnet.private[*].id
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDRs — for security group ingress rules"
  value       = aws_subnet.private[*].cidr_block
}

output "nat_gateway_ip" {
  description = "NAT Gateway public IP — whitelist this in external services"
  value       = aws_eip.nat.public_ip
}