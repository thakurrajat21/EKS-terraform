#############################################
# VPC
#############################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true          # set to false for production HA
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

#############################################
# Security Groups
#############################################

# Cluster security group (control plane)
resource "aws_security_group" "eks_cluster" {
  name_prefix = "${var.cluster_name}-cluster-"
  description = "EKS cluster security group"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

# Node group security group
resource "aws_security_group" "eks_nodes" {
  name_prefix = "${var.cluster_name}-nodes-"
  description = "EKS worker nodes security group"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "${var.cluster_name}-nodes-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# Allow nodes to talk to each other
resource "aws_security_group_rule" "nodes_internal" {
  description              = "Allow nodes to communicate with each other"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_nodes.id
}

# Allow worker nodes to communicate with the cluster API Server
resource "aws_security_group_rule" "nodes_cluster_inbound" {
  description              = "Allow worker nodes to communicate with the cluster API Server"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
}

# Allow control plane to talk to nodes (kubelet, etc.)
resource "aws_security_group_rule" "cluster_nodes_inbound" {
  description              = "Allow cluster control plane to communicate with worker nodes"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
}

# Optional: allow SSH into nodes (restrict CIDR in production!)
resource "aws_security_group_rule" "nodes_ssh" {
  description       = "Allow SSH access to worker nodes"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks       = ["0.0.0.0/0"]   # ← change this!
}

#############################################
# EKS Cluster
#############################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Control plane is private + public (you can make it fully private)
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Attach the security groups we created
  cluster_security_group_id = aws_security_group.eks_cluster.id
  # node_security_group_id is handled by the module / node groups below

  # Enable IRSA (recommended)
  enable_irsa = true

  # Managed node group
  eks_managed_node_groups = {
    default = {
      name = "${var.cluster_name}-ng"

      instance_types = var.node_instance_types

      min_size     = var.min_size
      max_size     = var.max_size
      desired_size = var.desired_size

      vpc_security_group_ids = [aws_security_group.eks_nodes.id]

      labels = {
        Environment = "dev"
      }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  # Optional: addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}
