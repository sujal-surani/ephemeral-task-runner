provider "aws" {
  region = "ap-south-1"
}

# General S3 Bucket for scripts, logs, and artifacts
resource "aws_s3_bucket" "task_workspace" {
  bucket = "ephemeral-workspace-${random_id.bucket_id.hex}"
}

resource "random_id" "bucket_id" {
  byte_length = 4
}

# Standard SQS Queue for generalized task triggers
resource "aws_sqs_queue" "task_queue" {
  name                      = "ephemeral-task-queue"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 86400 # Retain for 1 day
  receive_wait_time_seconds = 10    # Enables long polling to stay within Free Tier
}

output "sqs_queue_url" {
  value = aws_sqs_queue.task_queue.id
}

output "s3_bucket_name" {
  value = aws_s3_bucket.task_workspace.bucket
}