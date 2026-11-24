.DEFAULT_GOAL := test

.PHONY: test validate policies

test: validate policies

validate:
	hack/kubeconform.sh

policies:
	kyverno test tests/kyverno
