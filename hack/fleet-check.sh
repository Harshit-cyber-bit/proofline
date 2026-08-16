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

# Does the binary exist, and where. `ls` rather than running it, because
# running systemd is precisely the thing that is failing and this question
# should be answerable without it.
out=$(docker run --rm "$IMAGE" ls -lL /lib/systemd/systemd 2>&1 | head -2)
code=$?
if [[ $code -eq 0 ]]; then
    echo "    ${GREEN}yes${RESET}   /lib/systemd/systemd exists"
    printf '%s' "$DIM"; printf '%s\n' "$out" | indent "          "; printf '%s' "$RESET"
else
    echo "    ${RED}no${RESET}    /lib/systemd/systemd is not in the image (exit ${code})"
    printf '%s' "$DIM"; printf '%s\n' "$out" | indent "          "; printf '%s' "$RESET"
    echo ""
    echo "    Look for it:  docker run --rm $IMAGE sh -c 'command -v systemd; ls /sbin/init'"
    exit 1
fi

# Whether it will report its own version. Informative, never fatal: the boot
# attempts below are the real test, and an earlier version of this script
# aborted here and never reached them -- which taught me nothing except that a
# diagnostic with a hard gate in the middle is not a diagnostic.
out=$(docker run --rm "$IMAGE" /lib/systemd/systemd --version 2>&1 | head -1)
code=$?
if [[ $code -eq 0 && -n "${out//[[:space:]]/}" ]]; then
    echo "    ${GREEN}yes${RESET}   ${out}"
else
    echo "    ${YELLOW}odd${RESET}   'systemd --version' exited ${code}${out:+ saying: $out}"
    echo "          Not necessarily fatal -- systemd as PID 1 in a container can"
    echo "          fail before it has anywhere to print to. Continuing."
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
try_boot "privileged + cgroup mount" \
    --privileged -v /sys/fs/cgroup:/sys/fs/cgroup
try_boot "privileged + cgroupns=host" \
    --privileged --cgroupns=host
try_boot "cgroupns=host + cgroup mount" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup
try_boot "... + tmpfs /run /run/lock /tmp" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp
try_boot "... + container=docker env" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp -e container=docker

# ------------------------------------------------------------------ verdict

if [[ -n "$WINNER" ]]; then
    section "verdict"
    echo "    ${GREEN}${WINNER}${RESET} boots."
    echo ""
    echo "    Put this on docker_container \"fleet\" in terraform/local/main.tf:"
    echo ""
    case "$WINNER" in
        "privileged only")
            cat <<'HCL'
          privileged = true
          # and DELETE the volumes { host_path = "/sys/fs/cgroup" ... } block --
          # bind-mounting the host's cgroup tree over the one Docker already
          # set up is what was breaking it.
HCL
            ;;
        "privileged + cgroupns=host")
            cat <<'HCL'
          privileged    = true
          cgroupns_mode = "host"
          # and DELETE the volumes { host_path = "/sys/fs/cgroup" ... } block.
HCL
            ;;
        "privileged + cgroup mount"|"cgroupns=host + cgroup mount")
            echo "          (this is what terraform/local/main.tf already sets)"
            echo ""
            echo "    So the running containers differ from the code. Compare:"
            echo ""
            echo "        docker inspect $first --format '{{json .HostConfig}}' | python3 -m json.tool"
            echo ""
            echo "    then force a rebuild:"
            echo ""
            echo "        cd terraform/local && terraform apply -replace='docker_container.fleet[0]' \\"
            echo "          -replace='docker_container.fleet[1]' -replace='docker_container.fleet[2]' -auto-approve"
            exit 0
            ;;
        *tmpfs*|*container=docker*)
            cat <<'HCL'
          privileged    = true
          cgroupns_mode = "host"

          volumes {
            host_path      = "/sys/fs/cgroup"
            container_path = "/sys/fs/cgroup"
            read_only      = false
          }

          # systemd needs these writable and its own, not inherited from the
          # image layer.
          mounts {
            target = "/run"
            type   = "tmpfs"
          }

          mounts {
            target = "/run/lock"
            type   = "tmpfs"
          }

          mounts {
            target = "/tmp"
            type   = "tmpfs"
          }
HCL
            if [[ "$WINNER" == *"container=docker"* ]]; then
                echo ""
                echo '          env = ["container=docker"]'
            fi
            ;;
    esac
    echo ""
    echo "    Then:"
    echo ""
    echo "        cd terraform/local && terraform apply -auto-approve"
    echo "        cd ../.. && make fleet-check && make ansible"
    exit 0
fi

# `docker logs` on a container that died in its first half-second is often
# empty: the log driver never saw anything. Attaching to the foreground does
# see it. This is the attempt most likely to produce systemd's actual
# complaint, so it runs last and its output is printed whole.
section "attaching to the foreground, to catch what the log driver missed"
cleanup
foreground=$(timeout 12 docker run --rm --name "$TEST_NAME" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    "$IMAGE" /lib/systemd/systemd 2>&1 | head -40)
if [[ -n "${foreground//[[:space:]]/}" ]]; then
    printf '%s' "$DIM"; printf '%s\n' "$foreground" | indent "      "; printf '%s' "$RESET"
else
    echo "      (silent here too)"
fi

# And the other entry point, in case this image expects it.
cleanup
section "the same, via /sbin/init"
init_out=$(timeout 12 docker run --rm --name "$TEST_NAME" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    "$IMAGE" /sbin/init 2>&1 | head -40)
if [[ -n "${init_out//[[:space:]]/}" ]]; then
    printf '%s' "$DIM"; printf '%s\n' "$init_out" | indent "      "; printf '%s' "$RESET"
else
    echo "      (silent)"
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
    printf '%s\n' "      printf '[boot]\\nsystemd=true\\n' | sudo tee -a /etc/wsl.conf"
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
