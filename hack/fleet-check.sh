#!/usr/bin/env bash
#
# Why the Ansible fleet will not boot.
#
# The fleet containers run systemd as PID 1, so that the Ansible roles manage
# real systemd units and would work unchanged against EC2. systemd in a
# container is genuinely fussy, and when it fails it fails silently: the
# container exits 255 and `docker logs` prints nothing at all, because systemd
# dies before it has a console to complain to.
#
# Rather than guess, this reproduces the container by hand with each candidate
# fix and reports which one boots.
#
#   ./hack/fleet-check.sh
#
set -uo pipefail

IMAGE="${FLEET_IMAGE:-geerlingguy/docker-ubuntu2204-ansible:latest}"
PREFIX="${NAME_PREFIX:-proofline}"
TEST_NAME="proofline-fleet-check"

if [[ -t 1 ]]; then
    BOLD=$(tput bold); RED=$(tput setaf 1); GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3); RESET=$(tput sgr0)
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

cleanup() { docker rm -f "$TEST_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo ""
echo "${BOLD}the fleet as it stands${RESET}"
if ! docker ps -a --filter "name=${PREFIX}-app" --format '    {{.Names}}  {{.Status}}' | grep -q .; then
    echo "    no ${PREFIX}-app containers at all. Run: make terraform-local"
    exit 1
fi
docker ps -a --filter "name=${PREFIX}-app" --format '    {{.Names}}  {{.Status}}'

first="${PREFIX}-app-1"
echo ""
echo "${BOLD}how it was created${RESET}"
docker inspect "$first" \
    --format '    exit code:   {{.State.ExitCode}}
    error:       {{if .State.Error}}{{.State.Error}}{{else}}(none reported){{end}}
    command:     {{.Config.Cmd}}
    privileged:  {{.HostConfig.Privileged}}
    cgroup ns:   {{if .HostConfig.CgroupnsMode}}{{.HostConfig.CgroupnsMode}}{{else}}(unset -- daemon default){{end}}' \
    2>/dev/null || echo "    could not inspect $first"

echo ""
echo "${BOLD}the host${RESET}"
case "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" in
    cgroup2fs)
        echo "    cgroup v2 (unified)"
        V2=1
        ;;
    tmpfs)
        echo "    cgroup v1"
        V2=0
        ;;
    *)
        echo "    could not determine the cgroup version"
        V2=0
        ;;
esac

# The decisive test. Boot the same image by hand, once per candidate
# configuration, and see which survives five seconds. systemd that is going to
# fail fails immediately; systemd that gets past mounting its API filesystems
# stays up.
try_boot() {
    local label="$1"; shift
    cleanup
    if ! docker run -d --name "$TEST_NAME" "$@" "$IMAGE" /lib/systemd/systemd >/dev/null 2>&1; then
        printf '    %-38s %sdid not even start%s\n' "$label" "$RED" "$RESET"
        return 1
    fi
    sleep 5
    local status
    status=$(docker inspect "$TEST_NAME" --format '{{.State.Status}}' 2>/dev/null)
    if [[ "$status" == "running" ]]; then
        printf '    %-38s %sboots%s\n' "$label" "$GREEN" "$RESET"
        return 0
    fi
    printf '    %-38s %sexits (%s)%s\n' "$label" "$RED" "$status" "$RESET"
    return 1
}

echo ""
echo "${BOLD}booting the image by hand${RESET}"
echo "    (five seconds each -- systemd that is going to fail, fails at once)"
echo ""

as_configured=1
with_cgroupns=1

try_boot "privileged + /sys/fs/cgroup" \
    --privileged -v /sys/fs/cgroup:/sys/fs/cgroup && as_configured=0

try_boot "... and --cgroupns=host" \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup && with_cgroupns=0

echo ""
if [[ $as_configured -eq 0 ]]; then
    echo "  ${YELLOW}The image boots with exactly the configuration Terraform uses.${RESET}"
    echo "  So the fleet is failing for some other reason. Look at:"
    echo "      docker inspect $first --format '{{json .HostConfig}}' | python3 -m json.tool"
    exit 1
fi

if [[ $with_cgroupns -eq 0 ]]; then
    echo "  ${GREEN}Confirmed: the fleet needs --cgroupns=host.${RESET}"
    echo ""
    if [[ $V2 -eq 1 ]]; then
        echo "  On cgroup v2 the container gets its own cgroup namespace by default,"
        echo "  and systemd cannot write the controllers it needs inside it. Sharing"
        echo "  the host's namespace is what Molecule does to test roles in containers."
    fi
    echo ""
    echo "  terraform/local/main.tf already sets this. If the fleet is still"
    echo "  restarting, the running containers predate that change:"
    echo ""
    echo "      cd terraform/local && terraform apply -auto-approve"
    echo "      cd ../.. && ./hack/fleet-check.sh"
    echo ""
    echo "  If Terraform rejects cgroupns_mode as an unsupported argument, the"
    echo "  pinned kreuzwerker/docker provider is too old. Either bump it, or set"
    echo "  the daemon default and recreate:"
    echo ""
    echo '      echo "{\"default-cgroupns-mode\":\"host\"}" | sudo tee /etc/docker/daemon.json'
    echo "      sudo systemctl restart docker   # or: sudo service docker restart"
    exit 1
fi

echo "  ${RED}Neither configuration boots.${RESET}"
echo ""
echo "  That points at the host rather than the container. Two things to check:"
echo ""
echo "      systemctl is-system-running        # WSL2 needs systemd=true in /etc/wsl.conf"
echo "      docker info --format '{{.CgroupDriver}} {{.CgroupVersion}}'"
echo ""
echo "  You can finish the project without stage 4 -- stages 1-3 are the"
echo "  substance. Do not sink an evening into this one."
exit 1
