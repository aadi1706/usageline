# ecr

A private container registry for the API image.

- **Scan on push** is on, so each pushed image is checked for known vulnerabilities.
- **Tags are immutable** by default: a tag can never be re-pointed at a different image, which keeps deployments reproducible.
- **Lifecycle policy:** untagged images expire after 7 days and only the 20 most recent images are kept, so storage cost does not grow forever.
- Encrypted with KMS (the AWS-managed `aws/ecr` key unless `kms_key_arn` is given).
