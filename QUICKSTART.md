# Running proofline, step by step

Five stages, each independently useful. **Stage 2 is the one worth recording** —
you can stop there and still have the whole point of the repo on video.

Total time if nothing fights you: about 40 minutes. Stage 0 and 1 are ten of
those.

---

## On Windows? Start here instead

Two scripts do all of this for you.

**1. In an Administrator PowerShell** (enables WSL2, installs Ubuntu, sets
memory limits and systemd):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\hack\windows\bootstrap-windows.ps1
```

If it asks you to reboot, reboot and run it again — it resumes.

On 8 GB of RAM, run it as
`.\hack\windows\bootstrap-windows.ps1 -WslMemory 5GB -WslProcessors 2` instead.

**2. Inside Ubuntu** (installs Docker Engine, kind, kubectl, kustomize, helm,
Terraform, Ansible, then runs the whole demo):

```bash
wsl -d Ubuntu-24.04
cd ~ && unzip /mnt/c/Users/<you>/Downloads/proofline.zip
cd proofline
bash hack/windows/bootstrap-wsl.sh          # install + stages 0-2
bash hack/windows/bootstrap-wsl.sh --full   # also monitoring and Ansible
```

It is idempotent — if a step fails, fix it and re-run; it picks up where it
stopped. It finishes by printing your real numbers from both probe runs.

Two things it deliberately does **not** do: install Docker Desktop (Docker
Engine goes inside WSL2 instead — no licence question, and the cgroup layout the
Ansible fleet needs), and touch anything outside WSL beyond `%USERPROFILE%\.wslconfig`,
which it backs up first.

The rest of this document is the manual version, and the reference for when
something goes wrong.

---

## Stage 0 — Prove the repo is sound (2 minutes, no Docker)

```bash
unzip proofline.zip
cd proofline

pip install pytest pyyaml jsonschema python-hcl2 ansible-core ansible-lint ruff

make verify
```

**Expect:**

```
36 passed
all checks passed
Passed: 0 failure(s), 0 warning(s) ... Profile 'production' was required, and it passed.
```

That runs the unit tests, validates every Kubernetes manifest against the
upstream v1.31 schemas, parses all the Terraform, and lints the Ansible. If this
is green, everything except the cluster wiring is confirmed.

Prove the validator actually bites, while you are here:

```bash
sed -i 's/readinessProbe:/readinesProbe:/' k8s/base/deployment.yaml
python3 hack/validate.py        # expect FAIL
git checkout k8s/base/deployment.yaml
```

---

## Prerequisites for everything below

**Ubuntu / Debian / WSL2:**

```bash
# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER" && newgrp docker

# kubectl
curl -sSLo /tmp/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

# kind
curl -sSLo /tmp/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
sudo install -m 0755 /tmp/kind /usr/local/bin/kind

# kustomize
curl -sSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.4.3/kustomize_v5.4.3_linux_amd64.tar.gz" \
  | sudo tar xz -C /usr/local/bin

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# terraform
curl -sSLo /tmp/tf.zip https://releases.hashicorp.com/terraform/1.9.5/terraform_1.9.5_linux_amd64.zip
sudo unzip -o /tmp/tf.zip -d /usr/local/bin
```

**macOS:**

```bash
brew install kind kubectl kustomize helm terraform ansible
# plus Docker Desktop or Colima
```

Verify:

```bash
docker version && kind version && kubectl version --client \
  && kustomize version && helm version --short && terraform version
```

**Memory.** Stage 1 needs ~4 GB free, Stage 3 (Prometheus) another ~2 GB. On an
8 GB machine, edit `hack/kind-with-registry.sh` and delete two of the three
`- role: worker` lines before starting.

---

## Stage 1 — Cluster and a running service (10 minutes)

```bash
make cluster       # kind cluster + local registry
make namespaces    # proofline-dev / -staging / -prod
make build         # build the app image and push to localhost:5001
make deploy        # deploy to dev
```

**Check:**

```bash
kubectl --context kind-proofline get pods -n proofline-dev
# expect 2/2 Running

kubectl --context kind-proofline port-forward -n proofline-dev svc/proofline 8080:80 &
curl -s localhost:8080 | python3 -m json.tool
# {"service": "proofline-demo", "version": "dev", "ready": true, ...}
```

> **If `make build` fails on push:** the registry container is not on the kind
> network. `docker network connect kind kind-registry`, then retry.
>
> **If pods are `ImagePullBackOff`:** the containerd mirror did not take.
> `docker exec proofline-control-plane cat /etc/containerd/certs.d/localhost:5001/hosts.toml`
> should print `[host."http://kind-registry:5000"]`. If it is missing, re-run
> `./hack/kind-with-registry.sh`.

---

## Stage 2 — The proof (5 minutes) ⭐ record this

```bash
make prove
```

Forces a real rolling update and probes the Service throughout it.

**Expect:**

```
PASS  <several hundred> requests, 100.0% available, p99 <n>ms
```

Then the other half:

```bash
make break
```

Same service, safety settings removed — `maxUnavailable: 25%`, no preStop hook,
no drain, 60-second readiness period.

**Expect FAIL**, with consecutive `connection_error` failures and an estimated
downtime in seconds. It restores the safe overlay afterwards.

Run them back to back in one terminal. Green then red, about fifteen seconds of
video, and that is the LinkedIn post.

```bash
cat reports/dev/probe.json | python3 -m json.tool     # your real numbers
cat reports/broken/probe.json | python3 -m json.tool
```

> **If `make prove` FAILS:** do not raise the threshold. Look at
> `reports/dev/probe.json`. Consecutive `connection_error` means endpoint
> propagation — check the preStop hook and `terminationGracePeriodSeconds`
> survived into the running pod (`kubectl get deploy proofline -n proofline-dev -o yaml`).
> Scattered 5xx means the app. Whatever you find is the best paragraph in the blog.
>
> **If `make break` PASSES:** the unsafe overlay did not apply. Confirm with
> `kubectl get deploy proofline -n proofline-dev -o jsonpath='{.spec.strategy}'`
> — it should show `25%`, not `0`.

---

## Stage 3 — Monitoring and the SLO gate (10 minutes)

```bash
make terraform-local
```

Provisions the three-host fleet and installs kube-prometheus-stack, then applies
the SLO rules.

**Check:**

```bash
curl -s localhost:30090/-/healthy                 # Prometheus is Healthy
open http://localhost:30300                       # Grafana, admin / proofline

curl -s 'localhost:30090/api/v1/query?query=up{job="proofline"}' | python3 -m json.tool
# must return at least one result -- if empty, the ServiceMonitor is not matching
```

Then generate traffic and ask the gate:

```bash
make prove          # produces traffic as a side effect
make gate           # expect PASS
make burn           # inject 20% errors -- expect BLOCKED
```

> **If the gate says "no data":** Prometheus has not scraped the app under the
> `proofline` job label. Check
> `kubectl get svc -n proofline-dev --show-labels` for
> `app.kubernetes.io/name=proofline`, since the ServiceMonitor's `jobLabel`
> depends on it. Give it 60 seconds after deploying before judging.
>
> **On 8 GB:** if Prometheus gets OOMKilled, set `monitoring_enabled = false`
> and skip this stage. Stages 1, 2 and 4 do not need it.

---

## Stage 4 — The Ansible fleet (5 minutes)

```bash
make ansible
make ansible-idempotence      # second run must report changed=0
```

> **If the fleet containers exit immediately:** systemd in Docker needs the
> cgroup mount and, on cgroup v2 hosts, `cgroupns_mode = "host"`. Add that to
> the `docker_container "fleet"` resource in `terraform/local/main.tf` and
> re-apply. Check with `docker logs proofline-app-1`.
>
> **If the idempotence check fails:** run `ansible-playbook site.yml --diff` and
> find the task that reports changed on a second pass. This is the single most
> likely thing in the repo to need a fix, and the fix is worth writing up.

---

## Stage 5 — Jenkins (10 minutes, most likely to fight you)

```bash
make jenkins        # http://localhost:8081, admin / proofline
```

The controller is configured entirely from `jenkins/casc.yaml` — no setup
wizard, no clicking.

> **If the `proofline` job is missing:** check `make jenkins-logs` for JCasC
> errors. Job DSL scripts sometimes need approval the first time under
> **Manage Jenkins → In-process Script Approval**.
>
> **Before running the job:** update the repo URL in `jenkins/casc.yaml` to your
> own fork, and confirm the agent can reach the cluster:
> `docker exec proofline-jenkins kubectl --context kind-proofline get nodes`.

This stage is optional for the blog. Stages 1–3 are the substance; Jenkins is
the wrapper. If it resists, ship without it and add it later.

---

## Teardown

```bash
make down           # cluster, registry, Jenkins, Terraform state
```

---

## Recommended order for your week

| Day | Do |
|---|---|
| 1 | Stage 0, 1, 2. **Record `make prove` / `make break`.** |
| 2 | Stage 3. Capture the gate blocking on `make burn`. |
| 3 | Stage 4. Fix whatever the idempotence check finds. |
| 4 | Stage 5, or skip. Push to GitHub, confirm CI goes green. |
| 5 | Fill in real numbers, write the Medium post from your notes. |

Keep a scratch file of every problem you hit and how you fixed it. That file is
the blog post — "here is what the docs do not tell you" is the content people
search for and cannot find.
