# bootstrap

Creates the S3 bucket (and KMS key) that holds Terraform state for `envs/dev` and `envs/prod`. It is a separate folder because of a chicken-and-egg problem: Terraform cannot store state in a bucket that does not exist yet. This folder therefore uses **local state** and is applied once, by hand.

The bucket is versioned, KMS-encrypted, blocks all public access, denies non-TLS requests, and expires old state versions after 90 days.

## Locking

State locking uses **S3 native locking** (`use_lockfile = true` in the environments' backend block): Terraform writes a `.tflock` object next to the state with an S3 conditional write, and a second run fails if it already exists. This needs Terraform 1.10 or newer and **no DynamoDB table**. The older DynamoDB-based locking is deprecated in current Terraform, so a new setup should not depend on it.

## Using it

```bash
cd terraform/bootstrap
terraform init
terraform apply -var state_bucket_name=<globally-unique-name>   # needs AWS credentials; run by a human, once
terraform output -raw backend_config > ../envs/dev/backend.hcl   # then the same for prod
cd ../envs/dev && terraform init -backend-config=backend.hcl
```

Whoever runs Terraform needs, on the bucket: `s3:ListBucket`, and `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on the state keys (including the `.tflock` objects); plus `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey` on the key.
