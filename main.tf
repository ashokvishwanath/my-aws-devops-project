terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
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

# Kubernetes provider configuration using module outputs
data "aws_eks_cluster_auth" "default" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.default.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.default.token
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.default.token
  load_config_file       = false
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
  
  # Tags for Karpenter discovery
  private_subnet_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
  
  public_subnet_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = var.cluster_name
  cluster_version                = var.cluster_version
  subnet_ids                     = module.vpc.private_subnets
  vpc_id                         = module.vpc.vpc_id
  cluster_endpoint_public_access = true

  # Enable IAM roles for service accounts
  enable_irsa = true
  
  # Enable cluster creator admin permissions
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    general = {
      instance_types = [
        "t3a.medium"
      ]
      min_size       = 1
      max_size       = 5
      desired_size   = 2
      capacity_type  = "ON_DEMAND"
      
      # Add Karpenter discovery tags
      tags = {
        "karpenter.sh/discovery" = var.cluster_name
      }
    }
  }
  
  # Add Karpenter discovery tags to the cluster
  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# AWS Auth ConfigMap management
module "eks_aws_auth" {
  source  = "terraform-aws-modules/eks/aws//modules/aws-auth"
  version = "~> 20.0"

  manage_aws_auth_configmap = true

  aws_auth_roles = [
    {
      rolearn  = aws_iam_role.eks_admin.arn
      username = "eks-admin"
      groups   = ["system:masters"]
    },
  ]

  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::467025088240:user/CI-Admin"
      username = "ci-admin"
      groups   = ["system:masters"]
    },
  ]

  depends_on = [
    module.eks
  ]
}

# Karpenter Module for Node Provisioning
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  # Enable IRSA for Karpenter
  enable_irsa = true
  irsa_oidc_provider_arn = module.eks.oidc_provider_arn

  # Create node instance profile
  create_node_iam_role = true
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # SQS queue for interruption handling
  queue_name = "${var.cluster_name}-karpenter"

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }

  depends_on = [module.eks]
}

# Install Karpenter using Helm
resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.0.1"
  wait             = true
  wait_for_jobs    = true
  timeout          = 300

  values = [
    <<-EOT
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${module.karpenter.iam_role_arn}
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]

  depends_on = [module.karpenter]
}

# Karpenter NodePool Configuration
resource "kubectl_manifest" "karpenter_nodepool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        metadata:
          labels:
            karpenter.sh/nodepool: default
        spec:
          nodeClassRef:
            apiVersion: karpenter.k8s.aws/v1beta1
            kind: EC2NodeClass
            name: default
          capacity:
            cpu: 100
            memory: 100Gi
          taints:
            - key: karpenter.sh/default
              value: "true"
              effect: NoSchedule
      disruption:
        consolidationPolicy: WhenUnderutilized
        consolidateAfter: 30s
        expireAfter: 30m
      limits:
        cpu: 1000
        memory: 1000Gi
  YAML

  depends_on = [helm_release.karpenter]
}

# Karpenter EC2NodeClass Configuration
resource "kubectl_manifest" "karpenter_nodeclass" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      instanceStorePolicy: NVME
      userData: |
        #!/bin/bash
        /etc/eks/bootstrap.sh ${module.eks.cluster_name}
      amiFamily: AL2
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      instanceProfile: ${module.karpenter.instance_profile_name}
      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
        Name: "Karpenter-${module.eks.cluster_name}"
  YAML

  depends_on = [helm_release.karpenter]
}
