#!/usr/bin/env bash
# =============================================================================
# qos.sh — Apply / show / reset HTB QoS on pe2-left via netshoot netns
# Usage (from Ubuntu host):
#   docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/qos.sh apply
#   docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/qos.sh show
#   docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/qos.sh reset
#   docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/qos.sh verify
#
# How it works:
#   netshoot runs inside pe2-left's network namespace (--net container:pe2-left)
#   tc rules installed here live in that namespace and persist after netshoot exits
# =============================================================================

set -euo pipefail
source /etc/netshoot/netshoot.conf

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +"${TIMESTAMP_FORMAT}")]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

# The interface to shape — on pe2-left this is the SRv6 core-facing interface
IFACE="${QOS_INTERFACE}"

# Run commands inside pe2-left network namespace.
ns_ip() {
    docker run --rm \
        --net "container:${PE2_LEFT}" \
        --cap-add NET_ADMIN \
        "${NETSHOOT_IMAGE}" \
        ip "$@"
}

ns_tc() {
    docker run --rm \
        --net "container:${PE2_LEFT}" \
        --cap-add NET_ADMIN \
        "${NETSHOOT_IMAGE}" \
        tc "$@"
}

# -----------------------------------------------------------------------------
# APPLY — build the full HTB hierarchy
# -----------------------------------------------------------------------------
cmd_apply() {
    log "Applying HTB QoS on ${PE2_LEFT} ${IFACE}..."

    # Check interface exists
    if ! ns_ip link show "${IFACE}" &>/dev/null; then
        die "Interface ${IFACE} not found in ${PE2_LEFT} netns"
    fi

    # Remove existing qdisc if any (ignore error if none)
    ns_tc qdisc del dev "${IFACE}" root 2>/dev/null || true

    # Root HTB qdisc — unclassified traffic goes to default class 30
    ns_tc qdisc add dev "${IFACE}" root handle 1: htb default 30
    ok "Root HTB qdisc created (default → class 30)"

    # Root class — total bandwidth envelope
    ns_tc class add dev "${IFACE}" parent 1: classid 1:1 \
        htb rate "${QOS_TOTAL_RATE}"

    # CUSTOMER-A — guaranteed ${QOS_CA_RATE}, burst to ${QOS_CA_CEIL}
    ns_tc class add dev "${IFACE}" parent "${HTB_PARENT}" classid "${HTB_CLASS_CA}" \
        htb rate "${QOS_CA_RATE}" ceil "${QOS_CA_CEIL}" prio "${QOS_CA_PRIO}"
    ok "CUSTOMER-A class: rate=${QOS_CA_RATE} ceil=${QOS_CA_CEIL} prio=${QOS_CA_PRIO}"

    # CUSTOMER-B — guaranteed ${QOS_CB_RATE}, burst to ${QOS_CB_CEIL}
    ns_tc class add dev "${IFACE}" parent "${HTB_PARENT}" classid "${HTB_CLASS_CB}" \
        htb rate "${QOS_CB_RATE}" ceil "${QOS_CB_CEIL}" prio "${QOS_CB_PRIO}"
    ok "CUSTOMER-B class: rate=${QOS_CB_RATE} ceil=${QOS_CB_CEIL} prio=${QOS_CB_PRIO}"

    # Default class — leftover bandwidth
    ns_tc class add dev "${IFACE}" parent "${HTB_PARENT}" classid "${HTB_CLASS_DEF}" \
        htb rate "${QOS_DEFAULT_RATE}" ceil "${QOS_TOTAL_RATE}" prio 3
    ok "Default class: rate=${QOS_DEFAULT_RATE} ceil=${QOS_TOTAL_RATE}"

    # Add SFQ leaf qdisc to each class for fair queuing within the class
    ns_tc qdisc add dev "${IFACE}" parent "${HTB_CLASS_CA}" handle 10: sfq perturb 10
    ns_tc qdisc add dev "${IFACE}" parent "${HTB_CLASS_CB}" handle 20: sfq perturb 10
    ns_tc qdisc add dev "${IFACE}" parent "${HTB_CLASS_DEF}" handle 30: sfq perturb 10

    # ── Filters: classify traffic into HTB classes by DSCP (IPv6 TC field) ──

    # CUSTOMER-A: DSCP EF → TC byte 0xb8 (binary 10111000)
    # IPv6 TC field is bits 4-11 of the IPv6 header — u32 mask on 32-bit word
    ns_tc filter add dev "${IFACE}" parent 1: protocol ipv6 prio 1 \
        u32 \
        match u8 "${DSCP_CA_TC}" 0xfc at 1 \
        flowid "${HTB_CLASS_CA}"
    ok "Filter: IPv6 DSCP EF (${DSCP_CA_TC}) → CUSTOMER-A (${HTB_CLASS_CA})"

    # CUSTOMER-B: DSCP AF21 → TC byte 0x48
    ns_tc filter add dev "${IFACE}" parent 1: protocol ipv6 prio 2 \
        u32 \
        match u8 "${DSCP_CB_TC}" 0xfc at 1 \
        flowid "${HTB_CLASS_CB}"
    ok "Filter: IPv6 DSCP AF21 (${DSCP_CB_TC}) → CUSTOMER-B (${HTB_CLASS_CB})"

    ok "HTB QoS applied on ${IFACE}"
}

# -----------------------------------------------------------------------------
# SHOW — display current tc state with counters
# -----------------------------------------------------------------------------
cmd_show() {
    log "QoS state on pe2-left ${IFACE}"
    echo ""
    echo -e "${BOLD}── qdiscs ──────────────────────────────────────────────${NC}"
    ns_tc -s qdisc show dev "${IFACE}"
    echo ""
    echo -e "${BOLD}── classes ─────────────────────────────────────────────${NC}"
    ns_tc -s class show dev "${IFACE}"
    echo ""
    echo -e "${BOLD}── filters ─────────────────────────────────────────────${NC}"
    ns_tc filter show dev "${IFACE}"
}

# -----------------------------------------------------------------------------
# RESET — tear down all tc rules on the interface
# -----------------------------------------------------------------------------
cmd_reset() {
    log "Removing QoS from pe2-left ${IFACE}..."
    ns_tc qdisc del dev "${IFACE}" root 2>/dev/null && ok "QoS cleared" \
        || warn "No qdisc found on ${IFACE} — already clean"
}

# -----------------------------------------------------------------------------
# VERIFY — confirm QoS is correctly installed, exit 1 if not
# -----------------------------------------------------------------------------
cmd_verify() {
    log "Verifying QoS on pe2-left ${IFACE}..."
    local errors=0

    # Check root HTB exists
    if ns_tc qdisc show dev "${IFACE}" | grep -q "htb"; then
        ok "Root HTB qdisc present"
    else
        warn "Root HTB qdisc MISSING"
        errors=$((errors+1))
    fi

    # Check class CA exists
    if ns_tc class show dev "${IFACE}" | grep -q "${HTB_CLASS_CA}"; then
        ok "CUSTOMER-A class ${HTB_CLASS_CA} present"
    else
        warn "CUSTOMER-A class MISSING"
        errors=$((errors+1))
    fi

    # Check class CB exists
    if ns_tc class show dev "${IFACE}" | grep -q "${HTB_CLASS_CB}"; then
        ok "CUSTOMER-B class ${HTB_CLASS_CB} present"
    else
        warn "CUSTOMER-B class MISSING"
        errors=$((errors+1))
    fi

    # Check filters exist
    if ns_tc filter show dev "${IFACE}" | grep -q "u32"; then
        ok "DSCP filters present"
    else
        warn "DSCP filters MISSING"
        errors=$((errors+1))
    fi

    if [ "${errors}" -eq 0 ]; then
        ok "QoS configuration is complete and valid"
        return 0
    else
        die "QoS has ${errors} issue(s) — run: /etc/netshoot/qos.sh apply"
    fi
}

# -----------------------------------------------------------------------------
# WATCH — live counters refreshed every 2 seconds
# -----------------------------------------------------------------------------
cmd_watch() {
    log "Watching HTB counters on ${IFACE} (Ctrl+C to stop)..."
    while true; do
        clear
        echo -e "${BOLD}[$(date +"${TIMESTAMP_FORMAT}")] pe2-left ${IFACE} — HTB counters${NC}"
        echo "────────────────────────────────────────────────────"
        ns_tc -s class show dev "${IFACE}" | \
            awk '/class htb/{cls=$3} /Sent/{printf "  %-12s bytes=%-12s pkts=%s\n", cls, $2, $4}'
        sleep 2
    done
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
case "${1:-help}" in
    apply)   cmd_apply  ;;
    show)    cmd_show   ;;
    reset)   cmd_reset  ;;
    verify)  cmd_verify ;;
    watch)   cmd_watch  ;;
    help|*)
        echo "Usage: qos.sh <command>"
        echo ""
        echo "Commands:"
        echo "  apply   — install HTB QoS on pe2-left ${QOS_INTERFACE}"
        echo "  show    — display current qdiscs, classes, filters with counters"
        echo "  reset   — remove all QoS rules from the interface"
        echo "  verify  — check QoS is correctly installed (exit 1 if not)"
        echo "  watch   — live byte/packet counter refresh every 2s"
        echo ""
        echo "Run from Ubuntu host:"
        echo "  docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/qos.sh apply"
        ;;
esac
