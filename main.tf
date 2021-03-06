provider "aws" {
  region = var.region
}

module "terraform-aws-ecr" {
  source     = "github.com/prajavat/terraform-aws-ecr-image.git"
  enabled    = var.enabled
  name       = var.name
  stage      = var.stage
}

module "terraform-aws-ecs-cluster" {
  source                              = "github.com/prajavat/terrafrom-ecs-cluster-with-service.git"
  stage                               = var.stage
  region                              = var.region
  project                             = var.name
  image_repo_name                     = module.terraform-aws-ecr.registry_url
  instance_type                       = "t2.micro"
  key_name                            = "app-prod"
  root_block_device_size              = "20"
  desired_capacity                    = "1"
  min_size                            = "1"
  max_size                            = "2"
  min_capacity                        = "1"
  max_capacity                        = "10"
  health_check_path                   = "/"
  container_port                      = "80"
  deployment_minimum_healthy_percent  = "50"
  deployment_maximum_percent          = "200"
  abl_protocol                        = "HTTP"
}


resource "aws_s3_bucket" "default" {
  count         = var.enabled ? 1 : 0
  bucket        = local.cache_bucket_name_normalised
  acl           = "private"
  force_destroy = var.s3_bucket_force_destroy
  tags = {
    Attributes  = "codepipeline"
    Name  = local.cache_bucket_name_normalised
    Stage = var.stage
  }
}

resource "aws_iam_role" "default" {
  count              = var.enabled ? 1 : 0
  name               = local.codepipline_iam_role_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid = ""

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "default" {
  count      = var.enabled ? 1 : 0
  role       = join("", aws_iam_role.default.*.id)
  policy_arn = join("", aws_iam_policy.default.*.arn)
}

resource "aws_iam_policy" "default" {
  count  = var.enabled ? 1 : 0
  name   = local.codepipline_bucket_name
  policy = data.aws_iam_policy_document.default.json
}

data "aws_iam_policy_document" "default" {
  statement {
    sid = ""

    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "cloudwatch:*",
      "s3:*",
      "sns:*",
      "cloudformation:*",
      "rds:*",
      "sqs:*",
      "ecs:*",
      "iam:PassRole",
      "codecommit:*"
    ]

    resources = ["*"]
    effect    = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "s3" {
  count      = var.enabled ? 1 : 0
  role       = join("", aws_iam_role.default.*.id)
  policy_arn = join("", aws_iam_policy.s3.*.arn)
}

resource "aws_iam_policy" "s3" {
  count  = var.enabled ? 1 : 0
  name   = local.codepipline_iam_policy_name
  policy = join("", data.aws_iam_policy_document.s3.*.json)
}

data "aws_iam_policy_document" "s3" {
  count = var.enabled ? 1 : 0

  statement {
    sid = ""

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObject"
    ]

    resources = [
      join("", aws_s3_bucket.default.*.arn),
      "${join("", aws_s3_bucket.default.*.arn)}/*"
    ]

    effect = "Allow"
  }
}

resource "aws_iam_role_policy_attachment" "codebuild" {
  count      = var.enabled ? 1 : 0
  role       = join("", aws_iam_role.default.*.id)
  policy_arn = join("", aws_iam_policy.codebuild.*.arn)
}

resource "aws_iam_policy" "codebuild" {
  count  = var.enabled ? 1 : 0
  name   = local.codebuild_iam_policy_name
  policy = data.aws_iam_policy_document.codebuild.json
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid = ""

    actions = [
      "codebuild:*"
    ]

    resources = [module.codebuild.project_id]
    effect    = "Allow"
  }
}

module "codebuild" {
  source                = "./modules/terraform-aws-codebuild"
  enabled               = var.enabled
  name                  = var.name
  stage                 = var.stage
  build_image           = var.build_image
  build_compute_type    = var.build_compute_type
  build_timeout         = var.build_timeout
  buildspec             = var.buildspec
  privileged_mode       = var.privileged_mode
  image_repo_name       = module.terraform-aws-ecr.registry_url
  image_tag             = "latest"
  environment_variables = var.environment_variables
  badge_enabled         = var.badge_enabled
}

resource "aws_iam_role_policy_attachment" "codebuild_s3" {
  count      = var.enabled ? 1 : 0
  role       = module.codebuild.role_id
  policy_arn = join("", aws_iam_policy.s3.*.arn)
}

resource "aws_codepipeline" "default" {
  count    = var.enabled ? 1 : 0
  name     = local.codepipline_name
  role_arn = join("", aws_iam_role.default.*.arn)

  artifact_store {
    location = join("", aws_s3_bucket.default.*.bucket)
    type     = "S3"
  }

  depends_on = [
    aws_iam_role_policy_attachment.default,
    aws_iam_role_policy_attachment.s3,
    aws_iam_role_policy_attachment.codebuild,
    aws_iam_role_policy_attachment.codebuild_s3
  ]

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["code"]

      configuration = {
        RepositoryName       = var.repo_name
        BranchName            = var.branch
      }
    }
  }

  stage {
    name = "Build"

    action {
      name     = "Build"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"

      input_artifacts  = ["code"]
      output_artifacts = ["task"]

      configuration = {
        ProjectName = module.codebuild.project_name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["task"]
      version         = "1"

      configuration = {
        ClusterName = module.terraform-aws-ecs-cluster.ecs_cluster_name
        ServiceName = module.terraform-aws-ecs-cluster.ecs_service_name
      }
    }
  }
}
