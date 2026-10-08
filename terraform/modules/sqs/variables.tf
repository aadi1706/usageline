variable "name" {
  description = "Queue name. The dead-letter queue is named <name>-dlq."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "How long a received message is hidden from other consumers. Must exceed the consumer's processing time."
  type        = number
  default     = 60
}

variable "message_retention_seconds" {
  description = "How long messages stay in the main queue (default 4 days)."
  type        = number
  default     = 345600
}

variable "dlq_message_retention_seconds" {
  description = "How long failed messages stay in the dead-letter queue (14 days, the maximum)."
  type        = number
  default     = 1209600
}

variable "max_receive_count" {
  description = "Delivery attempts before a message is moved to the dead-letter queue."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
