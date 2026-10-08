# envs/local

Manages the Helm releases on the local kind cluster `kind-usageline` with Terraform: `kube-prometheus-stack` (using `monitoring/values.yaml`) and the `usageline` chart. The providers use the literal context `kind-usageline`, plus a precondition that every node name starts with `usageline-`, so this folder cannot touch any other cluster.

Terraform does **not** create the cluster, build the image, load it into kind or install metrics-server; those are done outside it (see the repo README). Pass the loaded image tag with `-var image_tag=<tag>`.

State is a local, git-ignored `terraform.tfstate`.
