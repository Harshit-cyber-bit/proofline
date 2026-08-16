#!/usr/bin/env bash
#
# Why the Ansible fleet will not boot.
#
# The fleet containers run systemd as PID 1, so the Ansible roles manage real
# systemd units and would work unchanged against EC2. systemd in a container is
# genuinely fussy, and when it fails it fails silently: the container exits 255
# and `docker logs` prints nothing, because systemd dies before it has anywhere
# to complain to.
#
# So this does not diagnose by reasoning. It boots the image by hand under a
# series of configurations, keeps the exit code and output of every one, and
# reports the first that survives -- or, if none do, everything it learned about
# the host on the way.
#
#   ./hack/fleet-check.sh
#
set -uo pipefail

IMAGE="${FLEET_IMAGE:-geerlingguy/docker-ubuntu2204-ansible:latest}"
PREFIX="${NAME_PREFIX:-proofline}"
TEST_NAME="proofline-fleet-check"

if [[ -t 1 ]]; then
    BOLD=$(tput bold); RED=$(tput setaf 1); GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3); DIM=$(tput dim); RESET=$(tput sgr0)
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; DIM=""; RESET=""
fi

cleanup() { docker rm -f "$TEST_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

section() { echo ""; echo "${BOLD}$1${RESET}"; }

# Indent a block of captured output. A while-read rather than sed, so the pad
# is applied to blank lines too and the whole thing survives odd characters in
# a systemd error message.
indent() {
    local pad="$1" line
    while IFS= read -r line; do printf '%s%s\n' "$pad" "$line"; done
}

# --------------------------------------------------------------- the fleet

section "the fleet as it stands"
if ! docker ps -a --filter "name=${PREFIX}-app" --format '    {{.Names}}  {{.Status}}' | grep -q .; then
    echo "    no ${PREFIX}-app containers at all. Run: make terraform-local"
    exit 1
fi
docker ps -a --filter "name=${PREFIX}-app" --format '    {{.Names}}  {{.Status}}'

first="${PREFIX}-app-1"
section "how it was created"
docker inspect "$first" \
    --format '    exit code:   {{.State.ExitCode}}
    error:       {{if .State.Error}}{{.State.Error}}{{else}}(none reported){{end}}
    command:     {{.Config.Cmd}}
    privileged:  {{.HostConfig.Privileged}}
    cgroup ns:   {{if .HostConfig.CgroupnsMode}}{{.HostConfig.CgroupnsMode}}{{else}}(unset -- daemon default){{end}}' \
    2>/dev/null || echo "    could not inspect $first"

# ----------------------------------------------------------------- the host
#
# Checked before the container, because a container cannot run systemd on a
# host that is not itself running systemd -- and on WSL2 that is the default.

section "the host"

host_pid1=$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')
echo "    PID 1:            ${host_pid1:-unknown}"

sysrun=$(systemctl is-system-running 2>&1 | head -1)
echo "    systemd:          ${sysrun}"

cgroup_fs=$(stat -fc %T /sys/fs/cgroup 2>/dev/null)
case "$cgroup_fs" in
    cgroup2fs) echo "    cgroups:          v2 (unified)"; V2=1 ;;
    tmpfs)     echo "    cgroups:          v1"; V2=0 ;;
    *)         echo "    cgroups:          could not determine"; V2=0 ;;
esac

controllers=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)
subtree=$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null)
if [[ $V2 -eq 1 ]]; then
    echo "    controllers:      ${controllers:-(none readable)}"
    echo "    subtree_control:  ${subtree:-(empty)}"
fi

docker info --format '    docker:           {{.CgroupDriver}} driver, cgroup v{{.CgroupVersion}}' 2>/dev/null

# On WSL2 without systemd, everything runs in the root cgroup. cgroup v2
# forbids enabling controllers on a cgroup that contains processes, so a
# container's systemd has nothing to delegate and gives up immediately --
# which is exactly the silent exit 255 this script exists to explain.
HOST_HAS_SYSTEMD=1
if [[ "$host_pid1" != "systemd" ]]; then
    HOST_HAS_SYSTEMD=0
fi

# ------------------------------------------------------------- can it run?

section "can the image run at all"
if out=$(docker run --rm "$IMAGE" /bin/true 2>&1); then
    echo "    ${GREEN}yes${RESET}   the image starts"
else
    echo "    ${RED}no${RESET}    the image itself will not start:"
    printf '%s' "$DIM"; printf '%s\n' "$out" | indent "          "; printf '%s' "$RESET"
    exit 1
fi

if out=$(docker run --rm "$IMAGE" /lib/systemd/systemd --version 2>&1 | head -1); then
    echo "    ${GREEN}yes${RESET}   ${out}"
else
    echo "    ${RED}no${RESET}    /lib/systemd/systemd is not runnable in this image:"
    printf '%s' "$DIM"; printf '%s\n' "$out" | indent "          "; printf '%s' "$RESET"
    exit 1
fi

# ------------------------------------------------------- boot, several ways
#
# Each candidate keeps its exit code and output. The previous version of this
# script reported only "exits", threw the logs away, and left the actual cause
# invisible -- the same mistake the fleet containers themselves were making.

declare -a LABELS=() RESULTS=() CODES=() LOGS=()
WINNER=""

try_boot() {
    local label="$1"; shift
    cleanup

    local start_err
    if ! start_err=$(docker run -d --name "$TEST_NAME" "$@" "$IMAGE" /lib/systemd/systemd 2>&1); then
        LABELS+=("$label"); RESULTS+=("would not start"); CODES+=("-")
        LOGS+=("$start_err")
        printf '    %-40s %sdid not start%s\n' "$label" "$RED" "$RESET"
        return 1
    fi

    sleep 5
    local status code logs
    status=$(docker inspect "$TEST_NAME" --format '{{.State.Status}}' 2>/dev/null)
    code=$(docker inspect "$TEST_NAME" --format '{{.State.ExitCode}}' 2>/dev/null)
    logs=$(docker logs "$TEST_NAME" 2>&1 | tail -25)

    LABELS+=("$label"); CODES+=("$code"); LOGS+=("$logs")
    if [[ "$status" == "running" ]]; then
        RESULTS+=("boots")
        printf '    %-40s %sboots%s\n' "$label" "$GREEN" "$RESET"
        [[ -z "$WINNER" ]] && WINNER="$label"
        return 0
    fi
    RESULTS+=("exited $code")
    printf '    %-40s %sexited %s%s\n' "$label" "$RED" "$code" "$RESET"
    return 1
}

section "booting the image by hand"
echo "    ${DIM}five seconds each -- systemd that is going to fail, fails at once${RESET}"
echo ""

# Ordered cheapest-first. On a modern daemon with cgroup v2, plain --privileged
# is often enough on its own, and bind-mounting the host's /sys/fs/cgroup over
# the one Docker already set up is what breaks it.
try_boot "privileged only" \
    --privileged
try_boot "privileged + /sys/fs/cgroup" \
    --privileged -v /sys/fs/cgroup:/sys/fs/cgroup
try_boot "privileged + cgroupns=host" \
    --privileged --cgroupns=host
try_boot "privileged + cgroupns=host + cgroup mount" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup
try_boot "... + tmpfs on /run and /tmp" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp
try_boot "... + container=docker" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp -e container=docker

# ------------------------------------------------------------------ verdict

if [[ -n "$WINNER" ]]; then
    section "verdict"
    echo "    ${GREEN}${WINNER}${RESET} boots."
    echo ""
    echo "    Set the matching options on docker_container \"fleet\" in"
    echo "    terraform/local/main.tf, then:"
    echo ""
    echo "        cd terraform/local && terraform apply -auto-approve"
    echo "        cd ../.. && ./hack/fleet-check.sh"
    exit 0
fi

section "what each attempt actually said"
for i in "${!LABELS[@]}"; do
    echo ""
    echo "  ${BOLD}${LABELS[$i]}${RESET} -- ${RESULTS[$i]}"
    if [[ -n "${LOGS[$i]//[[:space:]]/}" ]]; then
        printf '%s' "$DIM"; printf '%s\n' "${LOGS[$i]}" | indent "      "; printf '%s' "$RESET"
    else
        echo "${DIM}      (no output at all)${RESET}"
    fi
done

section "verdict"
if [[ $HOST_HAS_SYSTEMD -eq 0 ]]; then
    echo "  ${RED}The host is not running systemd. PID 1 is '${host_pid1}'.${RESET}"
    echo ""
    echo "  That is the cause, and no container flag fixes it. Under cgroup v2"
    echo "  every process here lives in the root cgroup, and cgroup v2 refuses to"
    echo "  enable controllers on a cgroup that contains processes -- so there is"
    echo "  nothing for a container's systemd to be delegated, and it exits before"
    echo "  it can say so."
    echo ""
    echo "  On WSL2, turn systemd on:"
    echo ""
    printf "      printf '[boot]\\nsystemd=true\\n' | sudo tee -a /etc/wsl.conf\n"
    echo ""
    echo "  then from PowerShell, close every WSL window and run:"
    echo ""
    echo "      wsl --shutdown"
    echo ""
    echo "  Reopen Ubuntu, start Docker (${BOLD}sudo service docker start${RESET} if it"
    echo "  does not come up on its own), then:"
    echo ""
    echo "      cd ~/proofline && make fleet-check"
    echo ""
    echo "  ${YELLOW}Note: 'wsl --shutdown' stops the kind cluster too.${RESET} It comes back"
    echo "  with 'docker start proofline-control-plane proofline-worker \\"
    echo "  proofline-worker2 proofline-worker3 kind-registry', or rebuild with"
    echo "  'make cluster && make namespaces && make build && make deploy'."
else
    echo "  ${RED}The host runs systemd and no container configuration boots.${RESET}"
    echo ""
    echo "  Read the output above -- with six attempts recorded, the failure is"
    echo "  in there. If every one is silent, the likeliest remaining cause is"
    echo "  cgroup delegation:"
    echo ""
    echo "      cat /sys/fs/cgroup/cgroup.subtree_control    # empty is a problem"
fi
echo ""
echo "  ${BOLD}This stage is optional.${RESET} Stages 1-3 are the substance of the"
echo "  project and they are done. Do not lose an evening here."
exit 1
