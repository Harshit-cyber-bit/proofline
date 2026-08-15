#!/usr/bin/env bash
# Install everything proofline needs, then run it end to end.
#
# Written for Ubuntu on WSL2, but works on any Debian/Ubuntu host. Run it after
# bootstrap-windows.ps1 has prepared the Windows side.
#
#   bash hack/windows/bootstrap-wsl.sh              # install, then run stages 0-2
#   bash hack/windows/bootstrap-wsl.sh --full       # also monitoring and Ansible
#   bash hack/windows/bootstrap-wsl.sh --install-only
#   bash hack/windows/bootstrap-wsl.sh --run-only
#
# Idempotent: every install step checks first, so re-running after a failure
# resumes rather than starting over.
set -o errexit
set -o nounset
set -o pipefail

KUBECTL_VERSION="v1.31.0"
KIND_VERSION="v0.24.0"
KUSTOMIZE_VERSION="v5.4.3"
TERRAFORM_VERSION="1.9.5"

MODE="default"
case "${1:-}" in
  --full)         MODE="full" ;;
  --install-only) MODE="install" ;;
  --run-only)     MODE="run" ;;
  "")             ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

BOLD=$(tput bold 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

step()  { echo ""; echo "${BOLD}==> $*${RESET}"; }
ok()    { echo "    ${GREEN}ok${RESET}   $*"; }
warn()  { echo "    ${YELLOW}warn${RESET} $*"; }
die()   { echo ""; echo "${RED}$*${RESET}" >&2; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------- preflight

preflight() {
  step "Preflight"

  [ -f /etc/debian_version ] || die "this script expects Debian or Ubuntu"
  # shellcheck source=/dev/null
  ok "$(. /etc/os-release && echo "${PRETTY_NAME}")"

  local mem_gb
  mem_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
  ok "${mem_gb} GB available to this VM"

  # awk, not bc: bc is installed by install_base, which runs after this.
  if awk -v m="${mem_gb}" 'BEGIN { exit !(m < 3.5) }'; then
    warn "under 4 GB -- raise memory in %USERPROFILE%\\.wslconfig, then 'wsl --shutdown'"
  fi

  # systemd matters: the Ansible fleet runs systemd inside containers, which
  # needs a systemd-managed cgroup hierarchy on the host.
  if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then
    ok "systemd is PID 1"
  else
    warn "systemd is NOT running (PID 1 is '$(ps -p 1 -o comm=)')"
    warn "stages 0-2 will still work; the Ansible fleet needs systemd"
    warn "fix: add '[boot]\\nsystemd=true' to /etc/wsl.conf, then 'wsl --shutdown'"
  fi

  # cgroup v2 is what makes systemd-in-Docker behave.
  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    ok "cgroup v2"
  else
    warn "cgroup v1 -- the Ansible fleet may need cgroupns_mode = \"host\""
  fi
}

# ----------------------------------------------------------------- installs

install_base() {
  step "Base packages"
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    ca-certificates curl gnupg unzip make git jq bc python3 python3-pip \
    >/dev/null
  ok "base packages present"
}

install_docker() {
  local codename
  step "Docker Engine"

  if have docker && sudo docker info >/dev/null 2>&1; then
    ok "docker already installed ($(docker --version | cut -d, -f1))"
  else
    # Docker Engine directly, not Docker Desktop: no licence question, no extra
    # service on the Windows side, and the cgroup layout the fleet needs.
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # shellcheck source=/dev/null
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${codename} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
      docker-compose-plugin >/dev/null
    ok "docker installed"
  fi

  if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
  else
    sudo service docker start >/dev/null 2>&1 || true
  fi

  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    ok "added ${USER} to the docker group"
    warn "group membership needs a new login shell"
    warn "this script will use 'sg docker' for the rest of the run"
  fi

  # sg gives this shell the group without requiring a re-login.
  if ! docker info >/dev/null 2>&1; then
    if sg docker -c "docker info" >/dev/null 2>&1; then
      ok "docker reachable via the docker group"
      export PROOFLINE_NEEDS_SG=1
    else
      die "docker is installed but not reachable. Try: wsl --shutdown (from Windows), reopen Ubuntu, re-run."
    fi
  else
    ok "docker reachable"
  fi
}

install_tool() {
  local name="$1" version_cmd="$2"
  if have "${name}"; then
    ok "${name} already installed ($(eval "${version_cmd}" 2>/dev/null | head -1))"
    return 0
  fi
  return 1
}

install_kubernetes_tools() {
  step "Kubernetes tooling"

  if ! install_tool kubectl "kubectl version --client -o yaml | grep gitVersion"; then
    curl -sSLo /tmp/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    ok "kubectl ${KUBECTL_VERSION}"
  fi

  if ! install_tool kind "kind version"; then
    curl -sSLo /tmp/kind \
      "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    sudo install -m 0755 /tmp/kind /usr/local/bin/kind
    ok "kind ${KIND_VERSION}"
  fi

  if ! install_tool kustomize "kustomize version"; then
    curl -sSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
      | sudo tar xz -C /usr/local/bin
    ok "kustomize ${KUSTOMIZE_VERSION}"
  fi

  if ! install_tool helm "helm version --short"; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
      | sudo bash >/dev/null
    ok "helm installed"
  fi
}

install_terraform() {
  step "Terraform"
  if install_tool terraform "terraform version | head -1"; then return; fi

  curl -sSLo /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
  sudo unzip -o -q /tmp/terraform.zip -d /usr/local/bin
  sudo chmod +x /usr/local/bin/terraform
  ok "terraform ${TERRAFORM_VERSION}"
}

install_python_tools() {
  step "Python tooling"
  # --break-system-packages because Ubuntu 24.04 marks the system Python as
  # externally managed. A venv would work too, but then every make target would
  # need to activate it first.
  pip3 install --quiet --break-system-packages \
    pytest pyyaml jsonschema python-hcl2 ansible-core ansible-lint ruff \
    2>/dev/null || pip3 install --quiet \
    pytest pyyaml jsonschema python-hcl2 ansible-core ansible-lint ruff

  # pip installs console scripts into ~/.local/bin, which is not always on PATH.
  if ! echo "${PATH}" | grep -q "${HOME}/.local/bin"; then
    export PATH="${HOME}/.local/bin:${PATH}"
    if ! grep -q '.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
      # shellcheck disable=SC2016  # the literal $HOME belongs in .bashrc
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
      ok "added ~/.local/bin to PATH in ~/.bashrc"
    fi
  fi
  ok "python tooling installed"
}

# --------------------------------------------------------------------- run

# Wrapper so every command works whether or not the docker group has taken
# effect in this shell yet.
run() {
  if [ "${PROOFLINE_NEEDS_SG:-0}" = "1" ]; then
    sg docker -c "cd '${REPO_ROOT}' && export PATH=\"${HOME}/.local/bin:\$PATH\" && $*"
  else
    bash -c "cd '${REPO_ROOT}' && export PATH=\"${HOME}/.local/bin:\$PATH\" && $*"
  fi
}

stage_verify() {
  step "Stage 0 -- offline verification (no cluster needed)"
  run "make verify"
  ok "tests, manifests, terraform and ansible all pass"
}

stage_cluster() {
  step "Stage 1 -- cluster, registry, build, deploy"
  run "make cluster"
  run "make namespaces"
  run "make build"
  run "make deploy"
  run "kubectl --context kind-proofline get pods -n proofline-dev"
  ok "service running in proofline-dev"
}

stage_prove() {
  step "Stage 2 -- the proof"

  echo ""
  echo "${BOLD}First: a correct rollout. Expect PASS.${RESET}"
  run "make prove" || die "make prove FAILED -- read reports/dev/probe.json before changing anything. Do not raise the threshold."

  echo ""
  echo "${BOLD}Now the same service with the safety settings removed. Expect FAIL.${RESET}"
  run "make break"

  # `make break` deliberately swallows the prober's exit code so it can restore
  # the safe overlay afterwards, so the exit status says nothing. Read the
  # verdict out of the report instead.
  if [ -f reports/broken/probe.json ] && python3 -c "
import json, sys
sys.exit(0 if json.load(open('reports/broken/probe.json'))['verdict']['passed'] else 1)
" 2>/dev/null; then
    warn "the broken rollout PASSED, which means the unsafe overlay did not apply"
    warn "check: kubectl get deploy proofline -n proofline-dev -o jsonpath='{.spec.strategy}'"
    warn "it should show 25%, not 0"
  else
    ok "the prober caught the broken rollout, as it should"
  fi
}

stage_monitoring() {
  step "Stage 3 -- monitoring and the SLO gate"
  run "make terraform-local"
  echo "    waiting 60s for Prometheus to scrape the app ..."
  sleep 60
  run "make prove"
  run "make gate" || warn "gate did not pass -- see the note in QUICKSTART.md about the job label"
}

stage_ansible() {
  step "Stage 4 -- the Ansible fleet"
  run "make ansible"
  run "make ansible-idempotence" || warn "the playbook is not idempotent yet -- run with --diff to find the task"
}

summary() {
  step "Summary"

  if [ -f reports/dev/probe.json ]; then
    echo ""
    echo "${BOLD}Correct rollout:${RESET}"
    python3 - <<'PY'
import json, pathlib
p = pathlib.Path("reports/dev/probe.json")
d = json.loads(p.read_text())["report"]
print(f"  requests            {d['total']}")
print(f"  dropped             {d['failed']}")
print(f"  availability        {d['availability_pct']}%")
print(f"  p99 latency         {d['latency_p99_ms']} ms")
print(f"  estimated downtime  {d['estimated_downtime_seconds']} s")
PY
  fi

  if [ -f reports/broken/probe.json ]; then
    echo ""
    echo "${BOLD}Rollout without the safety settings:${RESET}"
    python3 - <<'PY'
import json, pathlib
p = pathlib.Path("reports/broken/probe.json")
d = json.loads(p.read_text())["report"]
print(f"  requests            {d['total']}")
print(f"  dropped             {d['failed']}")
print(f"  availability        {d['availability_pct']}%")
print(f"  failures            {d['failures_by_class']}")
print(f"  estimated downtime  {d['estimated_downtime_seconds']} s")
PY
  fi

  echo ""
  echo "${GREEN}${BOLD}Those two numbers are your resume bullet and your LinkedIn post.${RESET}"
  echo ""
  echo "Next:"
  echo "  make prove && make break     # record this, green then red"
  echo "  make status                  # what is running"
  echo "  make down                    # tear it all down"
  echo ""
  if [ "${PROOFLINE_NEEDS_SG:-0}" = "1" ]; then
    warn "run 'exit' and reopen Ubuntu once, so the docker group applies to your"
    warn "normal shell -- otherwise 'make' commands will fail on docker permissions"
  fi
}

# -------------------------------------------------------------------- main

echo ""
echo "${BOLD}proofline bootstrap${RESET}"
echo "repository: ${REPO_ROOT}"

if [ "${MODE}" != "run" ]; then
  preflight
  install_base
  install_docker
  install_kubernetes_tools
  install_terraform
  install_python_tools
  step "Installation complete"
fi

if [ "${MODE}" = "install" ]; then
  echo ""
  echo "Now run: bash hack/windows/bootstrap-wsl.sh --run-only"
  exit 0
fi

stage_verify
stage_cluster
stage_prove

if [ "${MODE}" = "full" ]; then
  stage_monitoring
  stage_ansible
fi

summary
