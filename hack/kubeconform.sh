#!/usr/bin/env bash
# Validate Kubernetes manifests. Kustomize entrypoints are not resources.
# tests/ holds Kyverno CLI fixtures, including a Secret with a sops field
# that is not a core Secret field.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="${KUBERNETES_VERSION:-1.33.0}"
catalog="${CRD_CATALOG_REF:-04af58d740718c4dc719441bf39fb284c784f4a8}"
schema="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${catalog}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

mapfile -t files < <(
  find clusters infrastructure apps \
    -type f \( -name '*.yaml' -o -name '*.yml' \) \
    ! -name 'kustomization.yaml' \
    | sort
)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "no manifests found" >&2
  exit 1
fi

kubeconform \
  -strict \
  -summary \
  -kubernetes-version "$version" \
  -schema-location default \
  -schema-location "$schema" \
  "${files[@]}"
