terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "467025088240-demo-terraform-eks-state-s3-bucket"
    key            = "terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-eks-state-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name                 = var.cluster_name
  cidr                 = var.vpc_cidr
  azs                  = var.availability_zones
  private_subnets      = var.private_subnet_cidrs
  public_subnets       = var.public_subnet_cidrs
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                  = var.cluster_name
  cluster_version               = var.cluster_version
  subnet_ids                    = module.vpc.private_subnets
  vpc_id                        = module.vpc.vpc_id
  cluster_endpoint_public_access = true
  manage_aws_auth_configmap     = true

  eks_managed_node_groups = {
    general = {
      instance_types = [
        "t3a.medium"

        
      ]
      min_size       = 1
      max_size       = 5
      desired_size   = 2
      capacity_type  = "ON_DEMAND"
    }
  }

  aws_auth_roles = [
    {
      rolearn  = aws_iam_role.eks_admin.arn
      username = "eks-admin"
      groups   = ["system:masters"]
    }
  ]

  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::467025088240:user/CI-Admin"
      username = "ci-admin"
      groups   = ["system:masters"]
    }
  ]
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "EKSClusterAutoscalerPolicy"
  description = "Policy for EKS Cluster Autoscaler"
  policy      = file("${path.module}/cluster-autoscaler-policy.json")
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler_attach" {
  role       = module.eks.eks_managed_node_groups["general"].iam_role_name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

data "aws_iam_policy_document" "cluster_autoscaler_policy" {
  statement {
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "ec2:DescribeLaunchTemplateVersions"
    ]

    resources = ["*"]
  }
}