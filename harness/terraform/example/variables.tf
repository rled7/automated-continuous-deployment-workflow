variable "name" {
  description = "Prefix for every resource name."
  type        = string
  default     = "my-app"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}
