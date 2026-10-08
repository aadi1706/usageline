# sqs

A queue (intended for usage events) plus a **dead-letter queue (DLQ)**. A message that fails to be processed `max_receive_count` times (default 5) is moved to the DLQ instead of being retried forever, where it is kept for 14 days for inspection. The DLQ only accepts messages from the main queue.

Both queues use SQS-managed encryption at rest and have a policy that denies any non-TLS request. Alert on the DLQ's `ApproximateNumberOfMessagesVisible` metric in a real deployment (not created here).
