terraform {
  backend "s3" {
    bucket         = "1122-eks-lab-terraform-state"
    key            = "eks-lab/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true
  }

  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    tls = {
  source  = "hashicorp/tls"
  version = "~> 4.0"
}

  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "eks-security-lab"
      Environment = "lab"
      ManagedBy   = "terraform"
      Owner       = "zain"
    }
  }
}