output "repository_url" {
  description = "URL the pipeline pushes images to."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "ARN of the repository, for IAM policies."
  value       = aws_ecr_repository.this.arn
}
