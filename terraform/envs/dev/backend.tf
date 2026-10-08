# Remote state in the bucket created by ../../bootstrap. "bucket" and "region" are not hard-coded here;
# supply them at init time:  terraform init -backend-config=backend.hcl   (see backend.hcl.example).
terraform {
  backend "s3" {
    key          = "dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3 native locking (Terraform >= 1.10); no DynamoDB table needed
  }
}
