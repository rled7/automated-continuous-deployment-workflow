# `terraform test` applies the module for real (against Floci in the harness),
# checks these assertions, then destroys everything it created.

variables {
  name = "tftest"
}

run "creates_resources" {
  command = apply

  assert {
    condition     = aws_s3_bucket.artifacts.bucket == "tftest-artifacts"
    error_message = "artifacts bucket name should be derived from var.name"
  }

  assert {
    condition     = aws_s3_bucket_versioning.artifacts.versioning_configuration[0].status == "Enabled"
    error_message = "artifacts bucket must have versioning enabled"
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.deploy_events.redrive_policy).maxReceiveCount == 5
    error_message = "deploy events queue must redrive to the DLQ after 5 receives"
  }
}
