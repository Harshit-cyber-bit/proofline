#!/usr/bin/env bash
#
# Prove the dynamic inventory resolves to the fleet before running a playbook
# against it.
#
# This exists because of the specific way Ansible fails here. When an inventory
# plugin's config is wrong, Ansible logs a WARNING -- not an error -- falls back
# to the implicit localhost, and carries on. `hosts: all` then matches nothing,
# or worse, a playbook written with `hosts: localhost` anywhere in it quietly
# configures the machine you launched from.
#
# A warning is the wrong severity for "I am about to configure the wrong
# computer", so this turns it into an exit code.
#
#   ./hack/inventory-check.sh [expected-host-count]
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
EXPECTED="${1:-}"
INVENTORY="inventory/docker.yml"

if [[ -t 1 ]]; then
    BOLD=$(tput bold); RED=$(tput setaf 1); GREEN=$(tput setaf 2); DIM=$(tput dim)
    RESET=$(tput sgr0)
else
    BOLD=""; RED=""; GREEN=""; DIM=""; RESET=""
fi

indent() {
    local pad="$1" line
    while IFS= read -r line; do printf '%s%s\n' "$pad" "$line"; done
}

if ! command -v ansible-inventory >/dev/null 2>&1; then
    echo "  ${RED}ansible-inventory is not on PATH.${RESET}"
    echo "      pip install ansible-core   (and check ~/.local/bin is on PATH)"
    exit 1
fi

# stdout and stderr kept apart on purpose. stdout is JSON that has to parse;
# stderr is where this plugin puts its complaints. Folding them together, which
# is the obvious thing to do, corrupts the JSON with warning text and turns a
# config error into a confusing "no hosts found".
errfile=$(mktemp)
output=$(cd ansible && ansible-inventory -i "$INVENTORY" --list 2>"$errfile")
status=$?
errors=$(cat "$errfile"); rm -f "$errfile"

# The plugin reports config errors as warnings and still exits 0, so the exit
# code alone is not enough to trust.
if [[ $status -ne 0 ]] || grep -qi "Failed to parse\|Unable to parse" <<<"$errors"; then
    echo "  ${RED}the inventory did not parse.${RESET}"
    echo ""
    printf '%s' "$DIM"; printf '%s\n' "$errors" | grep -v '^ *$' | head -20 | indent "      "
    printf '%s' "$RESET"
    echo ""
    echo "  Ansible would treat this as a warning, fall back to the implicit"
    echo "  localhost, and run the playbook against this machine. It is an error."
    echo ""
    echo "  Most likely: an option in ${BOLD}ansible/${INVENTORY}${RESET} is the wrong shape for"
    echo "  the installed community.docker. Check what it actually accepts:"
    echo ""
    echo "      ansible-doc -t inventory community.docker.docker_containers"
    exit 1
fi

# Counted against the pattern site.yml actually targets, not against everything
# the inventory returns. The Docker inventory legitimately returns every
# container on the machine; what matters is how many of them the play will
# touch. "The inventory has hosts in it" is not the question.
read -r -d '' SPLIT <<'PY'
import json, sys
data = json.load(sys.stdin)
names = sorted(data.get("_meta", {}).get("hostvars", {}))
fleet = [n for n in names if n.startswith("proofline-app-")]
other = [n for n in names if n not in fleet and n != "localhost"]
print(len(fleet))
print("\n".join(fleet))
print("--")
print("\n".join(other))
PY

parsed=$(python3 -c "$SPLIT" <<<"$output" 2>/dev/null)
if [[ -z "$parsed" ]]; then
    echo "  ${RED}the inventory returned something that is not JSON.${RESET}"
    printf '%s' "$DIM"; printf '%s\n' "$output" | head -10 | indent "      "; printf '%s' "$RESET"
    exit 1
fi

count=$(head -1 <<<"$parsed")
fleet=$(sed -n '2,/^--$/p' <<<"$parsed" | sed '/^--$/d')
other=$(sed -n '/^--$/,$p' <<<"$parsed" | sed '1d')

if [[ "$count" -eq 0 ]]; then
    echo "  ${RED}the inventory parsed, but no fleet hosts are in it.${RESET}"
    echo ""
    if [[ -n "${other//[[:space:]]/}" ]]; then
        echo "  It did find these, which site.yml does not target:"
        printf '%s\n' "$other" | indent "      "
        echo ""
    fi
    echo "  The fleet is probably not running:"
    echo ""
    echo "      docker ps --filter name=proofline-app"
    echo "      make fleet-check"
    exit 1
fi

echo "  ${GREEN}${count} fleet host(s)${RESET} that site.yml will configure:"
printf '%s\n' "$fleet" | indent "      "
if [[ -n "${other//[[:space:]]/}" ]]; then
    other_count=$(grep -c . <<<"$other")
    echo "  ${DIM}${other_count} other container(s) in the inventory, not targeted${RESET}"
fi

if [[ -n "$EXPECTED" && "$count" -ne "$EXPECTED" ]]; then
    echo ""
    echo "  ${RED}expected ${EXPECTED}.${RESET} Part of the fleet is not running."
    exit 1
fi
exit 0
