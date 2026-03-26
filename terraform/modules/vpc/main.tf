# ─────────────────────────────────────────────
# DATA: Dynamically fetch available AZs
# ─────────────────────────────────────────────
# Why: Don't hardcode AZ names — they differ by account
# Some accounts don't have us-east-1e for example
data "aws_availability_zones" "available" {
  state = "available"
}

# ─────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # REQUIRED for EKS — nodes must resolve AWS service DNS
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

# ─────────────────────────────────────────────
# INTERNET GATEWAY
# ─────────────────────────────────────────────
# Why: Public subnets need this to reach internet
# NAT Gateway itself also uses this to route outbound traffic
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# ─────────────────────────────────────────────
# PUBLIC SUBNETS
# ─────────────────────────────────────────────
# Why public subnets exist in our setup:
#   1. NAT Gateway must live in a public subnet
#   2. Future: internet-facing Load Balancers go here
#   3. EKS nodes do NOT go here (they're in private)
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # Public subnets: instances launched here get public IPs
  # This is correct for NAT GW and LBs but NOT for worker nodes
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-${var.azs[count.index]}"

    # ELB/ALB controller discovers public subnets by this tag
    # Value "1" means: use this subnet for internet-facing load balancers
    "kubernetes.io/role/elb" = "1"

    # Tells EKS this subnet belongs to our cluster
    # "shared" means multiple clusters could use this subnet
    # "owned" would mean only our cluster uses it
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ─────────────────────────────────────────────
# PRIVATE SUBNETS
# ─────────────────────────────────────────────
# This is where ALL EKS worker nodes live
# No public IPs — nodes are completely unreachable from internet
# Outbound traffic routes through NAT Gateway
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # Private subnets: NO public IPs ever
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-private-${var.azs[count.index]}"

    # ELB controller discovers private subnets by this tag
    # Value "1" means: use for internal (private) load balancers
    "kubernetes.io/role/internal-elb" = "1"

    # Cluster ownership tag
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"

    # Karpenter REQUIRES this tag to discover which subnets
    # it is allowed to launch nodes into
    # Without this: Karpenter cannot provision any nodes
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# ─────────────────────────────────────────────
# NAT GATEWAY
# ─────────────────────────────────────────────
# Why only ONE NAT Gateway (not two, one per AZ):
#   Two NAT GWs = zone-independent architecture (production ideal)
#   but costs $32/month EACH = $64/month
#   One NAT GW = $32/month
#   Trade-off: if us-east-1a fails, nodes in 1b lose outbound internet
#   Acceptable for our lab. Real prod: one per AZ.
#
# Must live in PUBLIC subnet — it needs internet access itself
resource "aws_eip" "nat" {
  # EIP for the NAT Gateway
  # Without a static IP, NAT GW IP changes on recreate
  domain = "vpc"

  # NAT GW must exist before EIP is associated
  depends_on = [aws_internet_gateway.main]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id

  # NAT Gateway goes in FIRST public subnet (us-east-1a)
  subnet_id = aws_subnet.public[0].id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat-gw"
  })

  depends_on = [aws_internet_gateway.main]
}

# ─────────────────────────────────────────────
# ROUTE TABLES
# ─────────────────────────────────────────────

# Public route table — all outbound goes to Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-rt"
  })
}

# Private route table — all outbound goes through NAT Gateway
# This means nodes can INITIATE connections out (pull images, call AWS APIs)
# But nothing from internet can INITIATE connections inward
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-private-rt"
  })
}

# Associate public subnets → public route table
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Associate private subnets → private route table
resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ─────────────────────────────────────────────
# VPC ENDPOINT — S3 Gateway
# ─────────────────────────────────────────────
# Why: EKS nodes pull container images from ECR
#      ECR stores image layers in S3
#      Without this endpoint: S3 traffic goes through NAT = costs money
#      With Gateway endpoint: S3 traffic stays inside AWS network = FREE
#
# Gateway endpoints are different from Interface endpoints:
#   Gateway = FREE, works via route table, only S3 + DynamoDB
#   Interface = $7.20/month each, works via private DNS
#
# This single free endpoint saves meaningful NAT data costs
data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  # Add to private route table so node traffic to S3 bypasses NAT
  route_table_ids = [aws_route_table.private.id]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-s3-endpoint"
  })
}



# ─────────────────────────────────────────────
# STS VPC Endpoint
# Required for IRSA to work without internet
# EBS CSI, Karpenter, any IRSA pod needs this
# ─────────────────────────────────────────────
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.sts"
  vpc_endpoint_type   = "Interface"

  subnet_ids = [
    aws_subnet.private[0].id,
    aws_subnet.private[1].id
  ]

  security_group_ids = [aws_security_group.vpc_endpoints.id]

  private_dns_enabled = true

  tags = {
    Name = "${var.cluster_name}-sts-endpoint"
  }
}

# ─────────────────────────────────────────────
# EC2 VPC Endpoint
# Required for EBS CSI to call EC2 APIs
# ─────────────────────────────────────────────
resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.ec2"
  vpc_endpoint_type   = "Interface"

  subnet_ids = [
    aws_subnet.private[0].id,
    aws_subnet.private[1].id
  ]

  security_group_ids = [aws_security_group.vpc_endpoints.id]

  private_dns_enabled = true

  tags = {
    Name = "${var.cluster_name}-ec2-endpoint"
  }
}

# ─────────────────────────────────────────────
# Security Group for VPC Endpoints
# Allows HTTPS from within VPC
# ─────────────────────────────────────────────
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints"
  description = "Allow HTTPS to VPC endpoints from within VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "HTTPS from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-vpc-endpoints"
  }
}