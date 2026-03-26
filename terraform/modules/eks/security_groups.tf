
resource "aws_security_group" "cluster_additional" {
  name_prefix = "${var.cluster_name}-cluster-"
  description = "Additional security group for EKS control plane"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-cluster-sg"
  })


}


resource "aws_security_group" "nodes" {
  name_prefix = "${var.cluster_name}-nodes-"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nodes-sg"

   
    "karpenter.sh/discovery" = var.cluster_name
  })
}

resource "aws_security_group_rule" "nodes_to_control_plane_443" {
  security_group_id        = aws_security_group.cluster_additional.id
  description              = "Allow nodes to reach API server - required for kubelet registration"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nodes.id
}
resource "aws_security_group_rule" "nodes_to_cluster_primary_443" {
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description              = "Karpenter nodes reach API server - required for system pods"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nodes.id
}



resource "aws_security_group_rule" "nodes_internal" {
  security_group_id = aws_security_group.nodes.id
  description       = "Allow all traffic between nodes within cluster"
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1" # all protocols
  self              = true  # means: source = this same security group
}


resource "aws_security_group_rule" "control_plane_to_nodes" {
  security_group_id        = aws_security_group.nodes.id
  description              = "EKS control plane to node kubelet and webhook"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster_additional.id
}

resource "aws_security_group_rule" "nodes_egress" {
  security_group_id = aws_security_group.nodes.id
  description       = "Allow all outbound from nodes"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}