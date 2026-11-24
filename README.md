# gitops-secure-baseline

A forkable GitOps layout for one Kubernetes cluster. Flux reconciles this repo. Kyverno enforces a short list of rules. `apps/demo` is a service that already passes them.

> **This is a starting point, not production for you.** I would not hand this to a team and call the cluster done. There is no image signing, no identity for workloads, no backup, no second cluster, and the policy list is small on purpose. Fork it, delete what you do not mean, and add the controls that match what you actually run. Applying it unchanged and assuming you are covered will not make it so.

The longer version of why the rules belong in Git, next to the service, is [Security that arrives at the end of the sprint is already late](https://shafie.dev/notes/security-before-production/).

## Why Flux, and not Argo CD

Argo CD is what I reach for when a team wants an application UI, access split by project, and the same app promoted across several clusters. This repo is the other job: one cluster, one repository, a directory per layer.

Flux is enough for that. `clusters/local` holds three Kustomizations. One installs Kyverno, one applies the policies, one applies `apps/`. A service is a directory, not an Application object. Flux also decrypts SOPS while it reconciles, which is the secrets path below, so the controller does not need a plugin beside it. There is no dashboard. On a single cluster the pull request is the view I use.

## How a service gets onto the cluster

1. Copy `apps/demo` to `apps/<name>`. Keep a Namespace, the workload, and a NetworkPolicy for that namespace in the same directory.
2. Pin every image to a tag or a digest. Set CPU and memory requests on every container, including init containers. Do not set `privileged`. Do not use a hostPath volume. Do not commit a Secret. Encrypt it with [SOPS](https://fluxcd.io/flux/guides/mozilla-sops/) (Flux decrypts it) or create it with [External Secrets](https://external-secrets.io/) and commit the ExternalSecret, not the Secret.
3. Start from a default-deny ingress policy and add an allow for the traffic you actually want. `apps/demo` denies all ingress, then allows TCP 8080 from pods labeled `app.kubernetes.io/name: demo-client`.
4. Open a pull request. CI runs the same `make test` you can run locally. After merge, Flux applies `apps/` only once the policies are ready.

`kubectl apply -k apps/<name>` is the same YAML, if Flux is not installed yet. A manifest that never lands in Git is not part of the desired state. Kyverno rejects it at the API if it breaks a rule.

## Where the security rules live

The rules are Kyverno `ValidatingPolicy` resources. Kyverno 1.20, the chart pinned here, does not enforce the older `ClusterPolicy` type.

| Rule | File | What it rejects |
| --- | --- | --- |
| No privileged containers | `infrastructure/kyverno/policies/disallow-privileged.yaml` | `securityContext.privileged: true` on a container, init container, or ephemeral container |
| No floating images | `infrastructure/kyverno/policies/disallow-latest-tag.yaml` | A bare image name, or a tag of `latest`. A digest is accepted. A registry port is not treated as a tag |
| Requests required | `infrastructure/kyverno/policies/require-resource-requests.yaml` | A container or init container without CPU and memory requests. Ephemeral containers are not checked |
| No hostPath | `infrastructure/kyverno/policies/restrict-hostpath.yaml` | Any `hostPath` volume |
| No raw Secret in Git | `infrastructure/kyverno/git/disallow-raw-secrets.yaml` | A Secret manifest with no `sops.mac` entry |

The first four are installed on the cluster. They match Pods and the controllers that embed a pod template (Deployment, ReplicaSet, DaemonSet, StatefulSet, Job, CronJob), so a bad Deployment is rejected at apply time. They skip `kube-system`, `kyverno`, and `flux-system`. Those namespaces run components this set is not written for. Do not add an application namespace to that list.

They deny new and updated objects. A pod that is already running stays up until something updates it. A background scan reports it.

The Secret rule is different, and it is not installed. Flux strips SOPS metadata before apply, and External Secrets creates Secret objects in the cluster. An admission rule that rejected every Secret would block both. CI evaluates the file against Git, where an encrypted manifest still has `sops.mac`. Admission on that policy is off, so applying the file by mistake does not take the cluster down. The check that matters is `kyverno test`. `.sourceignore` also drops this file, and `tests/`, from the Flux artifact.

`apps/demo` also sets the baseline Pod Security Admission profile on its Namespace. That overlaps the privileged and hostPath rules. It does not cover image tags or resource requests.

## How a change is reviewed

A service change is a pull request under `apps/`. The diff should show the image, the requests, the NetworkPolicy, and no Secret.

A policy change is a pull request under `infrastructure/kyverno/`. `.github/CODEOWNERS` asks the baseline owners to review it. Say which workload broke and why the rule should change. An exception is usually the smaller change. Replace `@xoz-e` with the owners in your fork.

CI is the gate. [kubeconform](https://github.com/yannh/kubeconform) checks that the manifests are valid Kubernetes, including the Flux and Kyverno CRDs. `kyverno test` runs these policies against the demo app and against fixtures that are supposed to fail, including a privileged pod, a `:latest` tag, a missing tag, a missing request, a hostPath, an init container on `:latest`, a raw Secret, and a pod in `kube-system` that must be skipped. `make test` is that pipeline.

## Exceptions

Fix the workload if you can. If you cannot, add a `PolicyException` under `infrastructure/kyverno/policies/exceptions/` and list the file in that directory's kustomization. That directory is empty in this repo. Nothing is granted.

Keep the exception in the `kyverno` namespace, next to the controller. One policy, one workload. Set `expiresAt`. Kyverno stops honoring the exception after that time. Set `properties.reason` and `properties.ticket` so the next reader knows why it exists. An exception with no expiry does not get merged.

```yaml
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: log-agent-hostpath
  namespace: kyverno
spec:
  policyRefs:
    - kind: ValidatingPolicy
      name: restrict-hostpath
  expiresAt: "2026-12-31T00:00:00Z"
  properties:
    reason: "the log agent reads /var/log on the node"
    ticket: "PLAT-123"
  matchConditions:
    - name: only-that-agent
      expression: >-
        object.metadata.namespace == 'logging'
        && object.metadata.name.startsWith('fluent-bit')
```

This example is not applied. `PLAT-123` is a placeholder, not a real ticket.

## Try it locally

No cloud account. You need Docker, kubectl, and Helm. kind is the path below. k3d is the same after `k3d cluster create gitops-baseline`.

### The checks CI runs

Install kubeconform v0.8.0 and the Kyverno CLI v1.20.0. The checksums are in `.github/workflows/ci.yaml`.

```bash
make test
```

That validates every manifest under `clusters/`, `infrastructure/`, and `apps/`, then runs `kyverno test tests/kyverno`.

### kind, without Flux

```bash
kind create cluster --name gitops-baseline

helm upgrade --install kyverno kyverno \
  --repo https://kyverno.github.io/kyverno/ \
  --version 3.10.0 \
  --namespace kyverno \
  --create-namespace \
  --wait

kubectl apply -k infrastructure
kubectl apply -k apps
kubectl -n demo rollout status deploy/demo
kubectl -n demo exec deploy/demo-client -- wget -qO- http://demo:8080
```

The client is allowed. A pod in `demo` without that label is not, because ingress is denied unless the allow rule matches. Port-forward does not go through NetworkPolicy, so it is the wrong tool for checking the policy.

This should be rejected. The image tag is `latest`, and the baseline Pod Security profile does not care about that. Kyverno does.

```bash
kubectl apply -f tests/kyverno/resources/bad-latest.yaml
```

### kind, with Flux

Point Flux at a fork you can push to. Bootstrap against the kind cluster. It needs a GitHub token with access to that fork, not a hosted Kubernetes account.

`clusters/local/kustomization.yaml` already lists `flux-system`. That directory is not in the repo. Bootstrap writes it and pushes it. The sync path is `clusters/local`, so the Kustomizations next to `flux-system` are applied with Flux itself. The GitRepository bootstrap creates is named `flux-system`, which is what those Kustomizations reference.

```bash
flux bootstrap github \
  --token-auth \
  --owner=<you> \
  --repository=<your-fork> \
  --branch=main \
  --path=clusters/local \
  --personal
```

Kyverno is installed from the Helm release at chart `3.10.0`, then the policies, then `apps/`. When a service in `apps/` is encrypted with SOPS, uncomment `decryption` in `clusters/local/apps.yaml` and create the key Secret out of band. Do not commit the key.

## Layout

```text
clusters/local/                      Kustomizations for this cluster
infrastructure/kyverno/controller/   Kyverno Helm release
infrastructure/kyverno/policies/     rules installed on the cluster
infrastructure/kyverno/git/          Secret rule, CI only
apps/demo/                           namespace, workload, default-deny, allow
tests/kyverno/                       fixtures for kyverno test
```

## What this repo leaves out

Image signatures, digest-only admission, default-deny egress, a restricted Pod Security profile, a SOPS key, External Secrets itself, a second cluster, backups, and monitoring. Add those when you have a workload that needs them. Do not add a tenth policy because a sample catalog had one.

Maintained by [Hamidreza Shafie](https://shafie.dev). MIT, see `LICENSE`.

## فارسی

این repo را برای یک cluster نوشته‌ام تا بشود fork کرد و سرویس را از روی Git بالا آورد. policyها را کوتاه نگه داشته‌ام. فهرست بلند را کسی review نمی‌کند. pod با `privileged` ممنوع است. image باید tag مشخص داشته باشد و آن tag نباید `latest` باشد. request برای CPU و memory اجباری است. `hostPath` بسته است. Secret خام در Git جایی ندارد. یا manifest را با SOPS رمز می‌کنید و Flux موقع reconcile آن را decrypt می‌کند، یا External Secrets می‌سازدش.

این baseline، production شما نیست. امضای image، identity برای workload، backup و چند cluster این‌جا نیست. اگر قانونی با workload شما نمی‌خواند، در Git عوضش کنید. یک exception بی‌سروصدا جای این کار نیست.

سرویس جدید یک directory زیر `apps/` است، با NetworkPolicy همان namespace. ingress پیش‌فرض بسته است و فقط مسیر لازم باز می‌شود. تغییر با pull request می‌آید. CI همان kubeconform و Kyverno CLI را اجرا می‌کند که روی لپ‌تاپ با `make test` در دسترس است. قانون‌ها زیر `infrastructure/kyverno/` می‌مانند و جدا از manifest سرویس review می‌شوند. exception اگر واقعاً لازم شد باید نام policy را ببرد، به یک workload محدود باشد، دلیل داشته باشد و `expiresAt` داشته باشد. exception بدون تاریخ پایان merge نمی‌شود.

حرف کامل‌تر را، درباره اینکه امنیت باید از اول داخل کار باشد، این‌جا نوشته‌ام: <https://shafie.dev/notes/security-before-production/>

نگهدارنده: حمیدرضا شفیعی.
