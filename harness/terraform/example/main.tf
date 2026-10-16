# Example module so the terraform stage has something to exercise. It is plain
# AWS Terraform with no emulator settings: the harness points the provider at
# Floci from outside, the same way it would for any of your own modules.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.name}-artifacts"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = "${var.name}-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

resource "aws_sqs_queue" "deploy_events_dlq" {
  name = "${var.name}-deploy-events-dlq"
}

resource "aws_sqs_queue" "deploy_events" {
  name = "${var.name}-deploy-events"
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.deploy_events_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_iam_role" "deployer" {
  name = "${var.name}-deployer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "deployer_artifacts" {
  name = "artifacts-rw"
  role = aws_iam_role.deployer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "${aws_s3_bucket.artifacts.arn}/*"
    }]
  })
}
