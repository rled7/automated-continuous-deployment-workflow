output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "deploy_events_queue_url" {
  value = aws_sqs_queue.deploy_events.url
}

output "deployer_role_arn" {
  value = aws_iam_role.deployer.arn
}
