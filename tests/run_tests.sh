#!/usr/bin/env bash
# Composes a bundle with every service, then runs `terraform test` against it
# with mocked AWS providers (no credentials needed). Run in CI on every library change.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="${TF_BINARY:-$(command -v terraform || command -v tofu)}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

python3 "$ROOT/composer/compose.py" ec2 ecs lambda ecr s3 dynamodb -o "$OUT" --tf-binary "$TF" --no-zip
mkdir -p "$OUT/terraform-bundle/tests"
cp "$ROOT/tests/plan.tftest.hcl" "$OUT/terraform-bundle/tests/"
cd "$OUT/terraform-bundle"
"$TF" init -backend=false -input=false >/dev/null
"$TF" test
