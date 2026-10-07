#!/usr/bin/env bash
# Delete only the usageline kind cluster. Other containers and clusters are left alone.
set -euo pipefail
kind delete cluster --name usageline
