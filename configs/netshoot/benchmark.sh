#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — Run inside netshoot container (--net container:pe2-left)
# Sources netshoot.conf for all parameters
# Generates timestamped CSV + markdown report in /results
#
# Usage from host:
#   docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/benchmark.sh all
#   docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/benchmark.sh latency
#   docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/benchmark.sh convergence
#   docker exec clab-dual-plane-backbone-netshoot /etc/netshoot/benchmark.sh qos
# =============================================================================

set -euo pipefail
source /etc/netshoot/netshoot.conf

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

TS=$(date +%Y%m%d_%H%M%S)
RUN_DIR="${RESULTS_DIR}/${TS}"
mkdir -p "${RUN_DIR}"
CSV="${RUN_DIR}/raw.csv"
echo "scenario,metric,value,unit" > "${CSV}"

log()     { echo -e "${CYAN}[$(date +"${TIMESTAMP_FORMAT}")]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; }
section() {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"
}

save() {
    local scenario="$1" metric="$2" value="$3" unit="$4"
    echo "${scenario},${metric},${value},${unit}" >> "${CSV}"
    printf "  %-32s : ${BOLD}%s %s${NC}\n" "${metric}" "${value}" "${unit}"
}

# Run iperf3 server in a target container's netns via netshoot
start_server() {
    local target_node="$1" port="${2:-${IPERF_PORT}}"
    docker run -d --rm \
        --net "container:${target_node}" \
        --cap-add NET_ADMIN \
        "${NETSHOOT_IMAGE}" \
        iperf3 -s -p "${port}" --one-off 2>/dev/null
}

# Run iperf3 client in a source container's netns via netshoot
run_client_udp() {
    local src_node="$1" dst_ip="$2" port="${3:-${IPERF_PORT}}" bw="${4:-${IPERF_UDP_BW}}" tos="${5:-0x00}"
    docker run --rm \
        --net "container:${src_node}" \
        --cap-add NET_ADMIN \
        "${NETSHOOT_IMAGE}" \
        iperf3 -c "${dst_ip}" -p "${port}" \
            -u -b "${bw}" \
            -t "${IPERF_DURATION}" \
            -i "${IPERF_INTERVAL}" \
            --tos "${tos}" \
            -J 2>/dev/null || echo "{}"
}

run_client_tcp() {
    local src_node="$1" dst_ip="$2" port="${3:-${IPERF_PORT}}"
    docker run --rm \
        --net "container:${src_node}" \
        --cap-add NET_ADMIN \
        "${NETSHOOT_IMAGE}" \
        iperf3 -c "${dst_ip}" -p "${port}" \
            -t "${IPERF_DURATION}" \
            -i "${IPERF_INTERVAL}" \
            -J 2>/dev/null || echo "{}"
}

run_ping() {
    local src_node="$1" dst_ip="$2" count="${3:-${PING_COUNT}}" interval="${4:-${PING_INTERVAL}}"
    docker run --rm \
        --net "container:${src_node}" \
        "${NETSHOOT_IMAGE}" \
        ping -c "${count}" -i "${interval}" -q "${dst_ip}" 2>/dev/null || echo ""
}

parse_udp() {
    local json="$1" key="$2"
    printf '%s' "${json}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    end = d.get('end', {})
    u = end.get('sum', {})
    if not u and key == 'bits_per_second':
        # Some iperf3 versions expose throughput only in sum_sent/sum_received.
        u = end.get('sum_sent', {}) or end.get('sum_received', {})
    if not u:
        streams = end.get('streams', [])
        if streams:
            u = streams[0].get('udp', {})
    print(round(float(u.get('${key}', 0)), 3))
except:
    print('N/A')
" 2>/dev/null || echo "N/A"
}

parse_tcp_bps() {
    local json="$1"
    printf '%s' "${json}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    end = d.get('end', {})
    bps = (
        end.get('sum_received', {}).get('bits_per_second')
        or end.get('sum_sent', {}).get('bits_per_second')
        or 0
    )
    print(round(bps/1e6, 2))
except:
    print('N/A')
" 2>/dev/null || echo "N/A"
}

parse_ping() {
    local out="$1" key="$2"
    case "${key}" in
        loss)
            echo "${out}" | awk '/packet loss/ { gsub(/%.*/, ""); print $NF }' || echo "100"
            ;;
        min)
            echo "${out}" | awk '/^rtt/ { split($4, a, "/"); print a[1] }' || echo "N/A"
            ;;
        avg)
            echo "${out}" | awk '/^rtt/ { split($4, a, "/"); print a[2] }' || echo "N/A"
            ;;
        max)
            echo "${out}" | awk '/^rtt/ { split($4, a, "/"); print a[3] }' || echo "N/A"
            ;;
        mdev)
            echo "${out}" | awk '/^rtt/ { split($4, a, "/"); print a[4] }' || echo "N/A"
            ;;
    esac
}

kill_srv() { docker kill "$1" 2>/dev/null || true; }

vtysh_clean() {
    local node="$1"
    shift
    docker exec "${node}" vtysh "$@" 2>/dev/null | \
        grep -v "Can't open configuration file" | \
        grep -v "processing failure"
}

# =============================================================================
# SCENARIOS
# =============================================================================

run_srv6_native() {
    section "SRv6 router-native validation"

    local p1_isis p1_db pe2_loc pe2_sid pe2_v6

    p1_isis=$(vtysh_clean "${P1_SRV6}" -c "show isis neighbor")
    p1_db=$(vtysh_clean "${P1_SRV6}" -c "show isis database detail")
    pe2_loc=$(vtysh_clean "${PE2_LEFT}" -c "show segment-routing srv6 locator")
    pe2_sid=$(vtysh_clean "${PE2_LEFT}" -c "show segment-routing srv6 sid")
    pe2_v6=$(vtysh_clean "${PE2_LEFT}" -c "show ipv6 route")

    # Save raw control-plane snapshots for troubleshooting.
    printf '%s\n' "${p1_isis}" > "${RUN_DIR}/s0_p1_isis_neighbor.txt"
    printf '%s\n' "${p1_db}" > "${RUN_DIR}/s0_p1_isis_db_detail.txt"
    printf '%s\n' "${pe2_loc}" > "${RUN_DIR}/s0_pe2_left_locator.txt"
    printf '%s\n' "${pe2_sid}" > "${RUN_DIR}/s0_pe2_left_sid.txt"
    printf '%s\n' "${pe2_v6}" > "${RUN_DIR}/s0_pe2_left_ipv6_route.txt"

    ISIS_UP=$(printf '%s\n' "${p1_isis}" | awk '$0 ~ / Up / {c++} END {print c+0}')
    DB_LOCATORS=$(printf '%s\n' "${p1_db}" | awk '/SRv6 Locator:/ {c++} END {print c+0}')
    DB_ENDX=$(printf '%s\n' "${p1_db}" | awk '/SRv6 End.X SID:/ {c++} END {print c+0}')
    PE2_LOC_UP=$(printf '%s\n' "${pe2_loc}" | awk '$0 ~ /fd00:2::\/48/ && $0 ~ /Up/ {v=1} END {print v+0}')
    PE2_END=$(printf '%s\n' "${pe2_sid}" | awk '$0 ~ / End[[:space:]]/ {c++} END {print c+0}')
    PE2_ENDX=$(printf '%s\n' "${pe2_sid}" | awk '$0 ~ /End.X/ {c++} END {print c+0}')
    PE2_ENDDT4=$(printf '%s\n' "${pe2_sid}" | awk '$0 ~ /End.DT4/ {c++} END {print c+0}')
    PE2_SEG6LOCAL=$(printf '%s\n' "${pe2_v6}" | awk '$0 ~ /seg6local/ {c++} END {print c+0}')

    save "S0_srv6_native" "isis_neighbors_up" "${ISIS_UP}" "count"
    save "S0_srv6_native" "isis_db_srv6_locators" "${DB_LOCATORS}" "count"
    save "S0_srv6_native" "isis_db_srv6_endx" "${DB_ENDX}" "count"
    save "S0_srv6_native" "pe2_left_locator_up" "${PE2_LOC_UP}" "bool"
    save "S0_srv6_native" "pe2_left_sid_end" "${PE2_END}" "count"
    save "S0_srv6_native" "pe2_left_sid_endx" "${PE2_ENDX}" "count"
    save "S0_srv6_native" "pe2_left_sid_enddt4" "${PE2_ENDDT4}" "count"
    save "S0_srv6_native" "pe2_left_seg6local_routes" "${PE2_SEG6LOCAL}" "count"

    if [ "${DB_LOCATORS}" -gt 0 ] && [ "${DB_ENDX}" -gt 0 ] && [ "${PE2_ENDDT4}" -gt 0 ]; then
        ok "SRv6 control-plane evidence present (locator + End.X + End.DT4)"
    else
        warn "Missing expected SRv6 evidence in router state outputs"
    fi

    ok "SRv6 native validation complete → ${CSV}"
}

run_srv6_impact() {
    section "SRv6 service impact A/B test"

    local BASE_PING DEG_PING REC_PING
    local BASE_LOSS DEG_LOSS REC_LOSS
    local BASE_AVG DEG_AVG REC_AVG

    log "[S8] Baseline CUSTOMER-A reachability: ce7 -> ce5"
    BASE_PING=$(run_ping "${CE7}" "${CE5_IP}" 20 "0.2")
    BASE_LOSS=$(parse_ping "${BASE_PING}" loss); BASE_LOSS=${BASE_LOSS:-N/A}
    BASE_AVG=$(parse_ping "${BASE_PING}" avg); BASE_AVG=${BASE_AVG:-N/A}
    save "S8_srv6_impact" "baseline_loss_pct" "${BASE_LOSS}" "%"
    save "S8_srv6_impact" "baseline_avg_ms" "${BASE_AVG}" "ms"

    log "[S8] Disabling SRv6 VPN SID export on pe2-right (CUSTOMER-A)"
    docker exec "${PE2_RIGHT}" vtysh -c "conf t" \
        -c "router bgp 65000 vrf CUSTOMER-A" \
        -c "address-family ipv4 unicast" \
        -c "no sid vpn export auto" \
        -c "end" >/dev/null 2>&1 || true

    sleep 8

    log "[S8] Measure traffic after SRv6 SID withdrawal"
    DEG_PING=$(run_ping "${CE7}" "${CE5_IP}" 20 "0.2")
    DEG_LOSS=$(parse_ping "${DEG_PING}" loss); DEG_LOSS=${DEG_LOSS:-100}
    DEG_AVG=$(parse_ping "${DEG_PING}" avg); DEG_AVG=${DEG_AVG:-N/A}
    save "S8_srv6_impact" "degraded_loss_pct" "${DEG_LOSS}" "%"
    save "S8_srv6_impact" "degraded_avg_ms" "${DEG_AVG}" "ms"

    log "[S8] Restoring SRv6 VPN SID export on pe2-right (CUSTOMER-A)"
    docker exec "${PE2_RIGHT}" vtysh -c "conf t" \
        -c "router bgp 65000 vrf CUSTOMER-A" \
        -c "address-family ipv4 unicast" \
        -c "sid vpn export auto" \
        -c "end" >/dev/null 2>&1 || true

    sleep 8

    log "[S8] Measure traffic after SRv6 restore"
    REC_PING=$(run_ping "${CE7}" "${CE5_IP}" 20 "0.2")
    REC_LOSS=$(parse_ping "${REC_PING}" loss); REC_LOSS=${REC_LOSS:-N/A}
    REC_AVG=$(parse_ping "${REC_PING}" avg); REC_AVG=${REC_AVG:-N/A}
    save "S8_srv6_impact" "recovery_loss_pct" "${REC_LOSS}" "%"
    save "S8_srv6_impact" "recovery_avg_ms" "${REC_AVG}" "ms"

    # Keep a copy of raw ping outputs for troubleshooting.
    printf '%s\n' "${BASE_PING}" > "${RUN_DIR}/s8_baseline_ping.txt"
    printf '%s\n' "${DEG_PING}" > "${RUN_DIR}/s8_degraded_ping.txt"
    printf '%s\n' "${REC_PING}" > "${RUN_DIR}/s8_recovery_ping.txt"

    if [ "${DEG_LOSS}" = "100" ] || [ "${DEG_LOSS}" = "100.0" ]; then
        ok "SRv6 impact demonstrated: service breaks when SRv6 VPN SID export is removed"
    else
        warn "No hard outage observed in S8; topology redundancy may mask impact"
    fi

    ok "SRv6 impact test complete → ${CSV}"
}

run_latency() {
    section "Latency / Jitter / Packet Loss — all planes"

    # ── S1: intra SRv6 (ce7 → ce5) ──────────────────────────────────────────
    log "[S1] Intra-SRv6: ce7 → ce5"
    SRV=$(start_server "${CE5}"); sleep 2
    PING_OUT=$(run_ping "${CE7}" "${CE5_IP}")
    UDP_OUT=$(run_client_udp "${CE7}" "${CE5_IP}" "${IPERF_PORT}" "${IPERF_UDP_BW}" "0xb8")
    SRV2=$(start_server "${CE5}" $((IPERF_PORT+1))); sleep 1
    TCP_OUT=$(run_client_tcp "${CE7}" "${CE5_IP}" $((IPERF_PORT+1)))
    save "S1_SRv6" "latency_min_ms"  "$(parse_ping "${PING_OUT}" min)"  "ms"
    save "S1_SRv6" "latency_avg_ms"  "$(parse_ping "${PING_OUT}" avg)"  "ms"
    save "S1_SRv6" "latency_max_ms"  "$(parse_ping "${PING_OUT}" max)"  "ms"
    save "S1_SRv6" "latency_mdev_ms" "$(parse_ping "${PING_OUT}" mdev)" "ms"
    save "S1_SRv6" "ping_loss_pct"   "$(parse_ping "${PING_OUT}" loss)" "%"
    save "S1_SRv6" "jitter_ms"       "$(parse_udp  "${UDP_OUT}" jitter_ms)"    "ms"
    save "S1_SRv6" "udp_loss_pct"    "$(parse_udp  "${UDP_OUT}" lost_percent)" "%"
    save "S1_SRv6" "tcp_throughput"  "$(parse_tcp_bps "${TCP_OUT}")"           "Mbps"
    kill_srv "${SRV}"; kill_srv "${SRV2}" 2>/dev/null || true

    # ── S2: intra MPLS (ce3 → ce1) ───────────────────────────────────────────
    log "[S2] Intra-MPLS: ce3 → ce1"
    SRV=$(start_server "${CE1}"); sleep 2
    PING_OUT=$(run_ping "${CE3}" "${CE1_IP}")
    UDP_OUT=$(run_client_udp "${CE3}" "${CE1_IP}" "${IPERF_PORT}" "${IPERF_UDP_BW}" "0xb8")
    save "S2_MPLS" "latency_min_ms"  "$(parse_ping "${PING_OUT}" min)"  "ms"
    save "S2_MPLS" "latency_avg_ms"  "$(parse_ping "${PING_OUT}" avg)"  "ms"
    save "S2_MPLS" "latency_max_ms"  "$(parse_ping "${PING_OUT}" max)"  "ms"
    save "S2_MPLS" "latency_mdev_ms" "$(parse_ping "${PING_OUT}" mdev)" "ms"
    save "S2_MPLS" "ping_loss_pct"   "$(parse_ping "${PING_OUT}" loss)" "%"
    save "S2_MPLS" "jitter_ms"       "$(parse_udp  "${UDP_OUT}" jitter_ms)"    "ms"
    save "S2_MPLS" "udp_loss_pct"    "$(parse_udp  "${UDP_OUT}" lost_percent)" "%"
    kill_srv "${SRV}"

    # ── S3: cross-plane (ce7 SRv6 → ce3 MPLS) ───────────────────────────────
    log "[S3] Cross-plane Ships-in-the-Night: ce7 → ce3"
    SRV=$(start_server "${CE3}"); sleep 2
    PING_OUT=$(run_ping "${CE7}" "${CE3_IP}")
    UDP_OUT=$(run_client_udp "${CE7}" "${CE3_IP}" "${IPERF_PORT}" "${IPERF_UDP_BW}" "0xb8")
    save "S3_cross" "latency_min_ms"  "$(parse_ping "${PING_OUT}" min)"  "ms"
    save "S3_cross" "latency_avg_ms"  "$(parse_ping "${PING_OUT}" avg)"  "ms"
    save "S3_cross" "latency_mdev_ms" "$(parse_ping "${PING_OUT}" mdev)" "ms"
    save "S3_cross" "ping_loss_pct"   "$(parse_ping "${PING_OUT}" loss)" "%"
    save "S3_cross" "jitter_ms"       "$(parse_udp  "${UDP_OUT}" jitter_ms)"    "ms"
    save "S3_cross" "udp_loss_pct"    "$(parse_udp  "${UDP_OUT}" lost_percent)" "%"
    kill_srv "${SRV}"

    ok "Latency scenarios complete → ${CSV}"
}

run_convergence() {
    section "Convergence / Failover timing"

    # ── S4: IS-IS convergence (SRv6 plane) ───────────────────────────────────
    log "[S4] IS-IS convergence — killing p1-srv6 eth2"
    LOG4="${RUN_DIR}/s4_ping.txt"

    # Start continuous ping in background via netshoot in ce7 netns
    docker run --rm \
        --net "container:${CE7}" \
        "${NETSHOOT_IMAGE}" \
        ping -c "${PING_CONTINUOUS_COUNT}" -i "${PING_CONTINUOUS_INTERVAL}" \
             -D "${CE5_IP}" > "${LOG4}" &
    BG_PID=$!
    sleep 3

    FAIL_TS=$(date +%s%3N)
    docker exec "${P1_SRV6}" ip link set eth2 down
    log "Link down at ${FAIL_TS}ms — polling for recovery..."

    RECV_TS=""
    for _ in $(seq 1 $(( CONVERGENCE_TIMEOUT_S * 10 ))); do
        if docker run --rm --net "container:${CE7}" \
               "${NETSHOOT_IMAGE}" ping -c1 -W1 "${CE5_IP}" &>/dev/null; then
            RECV_TS=$(date +%s%3N); break
        fi
        sleep "${CONVERGENCE_POLL_INTERVAL}"
    done

    docker exec "${P1_SRV6}" ip link set eth2 up
    wait "${BG_PID}" 2>/dev/null || true

    if [ -n "${RECV_TS}" ]; then
        CONV_MS=$(( RECV_TS - FAIL_TS ))
        save "S4_isis_conv" "convergence_ms" "${CONV_MS}" "ms"
        save "S4_isis_conv" "convergence_s"  "$(echo "scale=3;${CONV_MS}/1000"|bc)" "s"
        ok "IS-IS convergence: ${CONV_MS} ms"
    else
        save "S4_isis_conv" "convergence_ms" "TIMEOUT" "ms"
        warn "No IS-IS recovery within ${CONVERGENCE_TIMEOUT_S}s"
    fi
    LOST4=$(grep -c "no answer" "${LOG4}" 2>/dev/null || true)
    LOST4=${LOST4:-0}
    save "S4_isis_conv" "pings_lost" "${LOST4}" "packets"

    # ── S5: OSPF convergence (MPLS plane) ────────────────────────────────────
    log "[S5] OSPF convergence — killing p1-mpls eth2"
    LOG5="${RUN_DIR}/s5_ping.txt"

    docker run --rm \
        --net "container:${CE3}" \
        "${NETSHOOT_IMAGE}" \
        ping -c "${PING_CONTINUOUS_COUNT}" -i "${PING_CONTINUOUS_INTERVAL}" \
             -D "${CE1_IP}" > "${LOG5}" &
    BG_PID=$!
    sleep 3

    FAIL_TS=$(date +%s%3N)
    docker exec "${P1_MPLS}" ip link set eth2 down

    RECV_TS=""
    for _ in $(seq 1 $(( CONVERGENCE_TIMEOUT_S * 10 ))); do
        if docker run --rm --net "container:${CE3}" \
               "${NETSHOOT_IMAGE}" ping -c1 -W1 "${CE1_IP}" &>/dev/null; then
            RECV_TS=$(date +%s%3N); break
        fi
        sleep "${CONVERGENCE_POLL_INTERVAL}"
    done

    docker exec "${P1_MPLS}" ip link set eth2 up
    wait "${BG_PID}" 2>/dev/null || true

    if [ -n "${RECV_TS}" ]; then
        CONV_MS=$(( RECV_TS - FAIL_TS ))
        save "S5_ospf_conv" "convergence_ms" "${CONV_MS}" "ms"
        save "S5_ospf_conv" "convergence_s"  "$(echo "scale=3;${CONV_MS}/1000"|bc)" "s"
        ok "OSPF convergence: ${CONV_MS} ms"
    else
        save "S5_ospf_conv" "convergence_ms" "TIMEOUT" "ms"
        warn "No OSPF recovery within ${CONVERGENCE_TIMEOUT_S}s"
    fi
    LOST5=$(grep -c "no answer" "${LOG5}" 2>/dev/null || true)
    LOST5=${LOST5:-0}
    save "S5_ospf_conv" "pings_lost" "${LOST5}" "packets"

    # ── S6: dual-plane PE failover (Ships-in-the-Night) ──────────────────────
    log "[S6] Ships-in-the-Night failover — stopping pe2-left BGP"
    LOG6="${RUN_DIR}/s6_ping.txt"

    docker run --rm \
        --net "container:${CE7}" \
        "${NETSHOOT_IMAGE}" \
        ping -c "${PING_CONTINUOUS_COUNT}" -i "${PING_CONTINUOUS_INTERVAL}" \
             -D "${CE5_IP}" > "${LOG6}" &
    BG_PID=$!
    sleep 3

    FAIL_TS=$(date +%s%3N)
    docker exec "${PE2_LEFT}" vtysh -c "conf t" \
        -c "router bgp 65000" -c "bgp default shutdown" -c "end" 2>/dev/null || \
    docker exec "${PE2_LEFT}" pkill -f bgpd 2>/dev/null || true

    RECV_TS=""
    for _ in $(seq 1 $(( FAILOVER_TIMEOUT_S * 10 ))); do
        if docker run --rm --net "container:${CE7}" \
               "${NETSHOOT_IMAGE}" ping -c1 -W1 "${CE5_IP}" &>/dev/null; then
            RECV_TS=$(date +%s%3N); break
        fi
        sleep "${CONVERGENCE_POLL_INTERVAL}"
    done

    # Restore
    docker exec "${PE2_LEFT}" vtysh -c "conf t" \
        -c "router bgp 65000" -c "no bgp default shutdown" -c "end" 2>/dev/null || \
    docker exec "${PE2_LEFT}" /usr/lib/frr/frrinit.sh start 2>/dev/null || true

    wait "${BG_PID}" 2>/dev/null || true

    if [ -n "${RECV_TS}" ]; then
        FO_MS=$(( RECV_TS - FAIL_TS ))
        save "S6_sitn_failover" "failover_ms" "${FO_MS}" "ms"
        save "S6_sitn_failover" "failover_s"  "$(echo "scale=3;${FO_MS}/1000"|bc)" "s"
        ok "Ships-in-the-Night failover: ${FO_MS} ms"
    else
        save "S6_sitn_failover" "failover_ms" "TIMEOUT" "ms"
        warn "No failover within ${FAILOVER_TIMEOUT_S}s — check BGP hold-timer / BFD"
    fi
    LOST6=$(grep -c "no answer" "${LOG6}" 2>/dev/null || true)
    LOST6=${LOST6:-0}
    save "S6_sitn_failover" "pings_lost" "${LOST6}" "packets"

    ok "Convergence scenarios complete → ${CSV}"
}

run_qos() {
    section "QoS effectiveness — CUSTOMER-A vs CUSTOMER-B under contention"

    # Verify QoS is applied before running
    if ! docker run --rm \
           --net "container:${PE2_LEFT}" --cap-add NET_ADMIN \
           "${NETSHOOT_IMAGE}" tc qdisc show dev "${QOS_INTERFACE}" 2>/dev/null \
           | grep -q "htb"; then
        warn "HTB not found on pe2-left — applying QoS first..."
        /etc/netshoot/qos.sh apply
    fi

    log "[S7] QoS contention: both customers push ${IPERF_CONTENTION_BW} simultaneously"
    SRV_A=$(start_server "${CE5}" "${IPERF_PORT}"); sleep 1
    SRV_B=$(start_server "${CE1}" "${IPERF_PORT_B}"); sleep 1

    # Run both streams simultaneously, save JSON output
    LOG_A="${RUN_DIR}/s7_cust_a.json"
    LOG_B="${RUN_DIR}/s7_cust_b.json"

    docker run --rm \
        --net "container:${CE7}" --cap-add NET_ADMIN \
        "${NETSHOOT_IMAGE}" \
        iperf3 -c "${CE5_IP}" -p "${IPERF_PORT}" \
            -u -b "${IPERF_CONTENTION_BW}" \
            -t "${IPERF_DURATION}" --tos 0xb8 -J \
        > "${LOG_A}" &
    PID_A=$!

    docker run --rm \
        --net "container:${CE3}" --cap-add NET_ADMIN \
        "${NETSHOOT_IMAGE}" \
        iperf3 -c "${CE1_IP}" -p "${IPERF_PORT_B}" \
            -u -b "${IPERF_CONTENTION_BW}" \
            -t "${IPERF_DURATION}" --tos 0x48 -J \
        > "${LOG_B}" &
    PID_B=$!

    wait "${PID_A}" "${PID_B}"

    # Transient iperf control-channel errors can occur under concurrent startup.
    # Retry both streams once to keep QoS KPI collection deterministic.
    if grep -q '"error"' "${LOG_A}" 2>/dev/null || grep -q '"error"' "${LOG_B}" 2>/dev/null; then
        warn "QoS iperf stream error detected, retrying contention test once..."
        SRV_A=$(start_server "${CE5}" "${IPERF_PORT}"); sleep 1
        SRV_B=$(start_server "${CE1}" "${IPERF_PORT_B}"); sleep 1

        docker run --rm \
            --net "container:${CE7}" --cap-add NET_ADMIN \
            "${NETSHOOT_IMAGE}" \
            iperf3 -c "${CE5_IP}" -p "${IPERF_PORT}" \
                -u -b "${IPERF_CONTENTION_BW}" \
                -t "${IPERF_DURATION}" --tos 0xb8 -J \
            > "${LOG_A}" &
        PID_A=$!

        docker run --rm \
            --net "container:${CE3}" --cap-add NET_ADMIN \
            "${NETSHOOT_IMAGE}" \
            iperf3 -c "${CE1_IP}" -p "${IPERF_PORT_B}" \
                -u -b "${IPERF_CONTENTION_BW}" \
                -t "${IPERF_DURATION}" --tos 0x48 -J \
            > "${LOG_B}" &
        PID_B=$!

        wait "${PID_A}" "${PID_B}"
    fi

    kill_srv "${SRV_A}"; kill_srv "${SRV_B}"

    CA_BW=$(parse_udp  "$(cat "${LOG_A}")" "bits_per_second")
    CA_BW_M=$(echo "scale=2; ${CA_BW:-0}/1000000" | bc 2>/dev/null || echo "N/A")
    CA_J=$(parse_udp   "$(cat "${LOG_A}")" "jitter_ms")
    CA_L=$(parse_udp   "$(cat "${LOG_A}")" "lost_percent")

    CB_BW=$(parse_udp  "$(cat "${LOG_B}")" "bits_per_second")
    CB_BW_M=$(echo "scale=2; ${CB_BW:-0}/1000000" | bc 2>/dev/null || echo "N/A")
    CB_J=$(parse_udp   "$(cat "${LOG_B}")" "jitter_ms")
    CB_L=$(parse_udp   "$(cat "${LOG_B}")" "lost_percent")

    save "S7_qos" "cust_a_throughput_mbps" "${CA_BW_M}" "Mbps"
    save "S7_qos" "cust_a_jitter_ms"       "${CA_J}"    "ms"
    save "S7_qos" "cust_a_loss_pct"        "${CA_L}"    "%"
    save "S7_qos" "cust_b_throughput_mbps" "${CB_BW_M}" "Mbps"
    save "S7_qos" "cust_b_jitter_ms"       "${CB_J}"    "ms"
    save "S7_qos" "cust_b_loss_pct"        "${CB_L}"    "%"

    # Ratio analysis
    if [ "${CA_BW_M}" != "N/A" ] && [ "${CB_BW_M}" != "N/A" ] && [ "${CB_BW_M}" != "0" ] && [ "${CB_BW_M}" != "0.00" ]; then
        RATIO=$(echo "scale=2; ${CA_BW_M}/${CB_BW_M}" | bc 2>/dev/null || echo "N/A")
        save "S7_qos" "priority_ratio_a_over_b" "${RATIO}" "x"
        if (( $(echo "${RATIO} > 1.5" | bc -l 2>/dev/null || echo 0) )); then
            ok "QoS effective: CUSTOMER-A gets ${RATIO}x more bandwidth under contention"
        else
            warn "QoS ratio ${RATIO}x < 1.5 — check tc filters or DSCP marking"
        fi
    fi

    ok "QoS scenario complete → ${CSV}"
}

print_table() {
    section "Results table"
    python3 - "${CSV}" <<'PYEOF'
import csv, sys
from collections import defaultdict

data = defaultdict(dict)
with open(sys.argv[1]) as f:
    for row in csv.DictReader(f):
        data[row['scenario']][row['metric']] = f"{row['value']} {row['unit']}"

scenarios   = list(data.keys())
all_metrics = sorted({m for s in data.values() for m in s})
col = 26

print(f"\n{'Metric':<34}", end="")
for s in scenarios:
    print(f"{s[:col]:<{col+2}}", end="")
print()
print("─" * (34 + (col+2)*len(scenarios)))
for m in all_metrics:
    print(f"{m:<34}", end="")
    for s in scenarios:
        print(f"{data[s].get(m,'—')[:col]:<{col+2}}", end="")
    print()
print(f"\nCSV: {sys.argv[1]}")
PYEOF
}

write_report() {
    local rpt="${RUN_DIR}/report.md"
    cat > "${rpt}" <<MDEOF
# Dual-Plane Backbone — Benchmark Report
**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Tool:** nicolaka/netshoot
**Lab:** dual-plane-backbone

## Scenarios
| ID | Name | Path | Metric |
|----|------|------|--------|
| S0 | SRv6 native state | FRR vtysh on SRv6 nodes | IS-IS SRv6 DB, locator, End.X, End.DT4 evidence |
| S8 | SRv6 impact A/B   | ce7 → ce5 with SID withdrawal | baseline/degraded/recovery loss and latency |
| S1 | SRv6 baseline     | ce7 → ce5             | latency, jitter, loss, TCP throughput |
| S2 | MPLS baseline     | ce3 → ce1             | latency, jitter, loss |
| S3 | Cross-plane       | ce7 → ce3             | Ships-in-the-Night overhead |
| S4 | IS-IS convergence | p1-srv6 eth2 down     | convergence time, pings lost |
| S5 | OSPF convergence  | p1-mpls eth2 down     | convergence time, pings lost |
| S6 | SitN failover     | pe2-left BGP shutdown | failover time, pings lost |
| S7 | QoS contention    | ce7+ce3 → 80Mbit each | CUSTOMER-A vs B throughput ratio |

## Files
- \`raw.csv\` — all raw metrics
- \`s0_p1_isis_neighbor.txt\` — SRv6/IS-IS neighbor snapshot from p1-srv6
- \`s0_p1_isis_db_detail.txt\` — IS-IS DB detail showing SRv6 TLVs
- \`s0_pe2_left_locator.txt\` — local SRv6 locator state on pe2-left
- \`s0_pe2_left_sid.txt\` — local SRv6 SIDs (End / End.X / End.DT4)
- \`s0_pe2_left_ipv6_route.txt\` — IPv6 RIB with seg6local entries
- \`s8_baseline_ping.txt\` — S8 baseline ping summary
- \`s8_degraded_ping.txt\` — S8 ping summary after SID withdrawal
- \`s8_recovery_ping.txt\` — S8 ping summary after SID restore
- \`s4_ping.txt\` — continuous ping log during IS-IS failure
- \`s5_ping.txt\` — continuous ping log during OSPF failure
- \`s6_ping.txt\` — continuous ping log during SitN failover
- \`s7_cust_a.json\` — iperf3 JSON CUSTOMER-A QoS test
- \`s7_cust_b.json\` — iperf3 JSON CUSTOMER-B QoS test
MDEOF
    ok "Report written: ${rpt}"
}

# =============================================================================
# MAIN DISPATCH
# =============================================================================
case "${1:-help}" in
    all)
        run_srv6_native
        run_srv6_impact
        run_latency
        run_convergence
        run_qos
        print_table
        write_report
        ;;
    srv6)        run_srv6_native; print_table; write_report ;;
    srv6-impact) run_srv6_impact; print_table; write_report ;;
    latency)     run_latency;     print_table; write_report ;;
    convergence) run_convergence; print_table; write_report ;;
    qos)         run_qos;         print_table; write_report ;;
    table)       print_table ;;
    help|*)
        echo "Usage: benchmark.sh <command>"
        echo ""
        echo "Commands:"
        echo "  srv6         — S0 router-native SRv6 validation"
        echo "  srv6-impact  — S8 A/B impact test by withdrawing SRv6 VPN SID export"
        echo "  all          — run all 9 scenarios"
        echo "  latency      — S1 SRv6 / S2 MPLS / S3 cross-plane"
        echo "  convergence  — S4 IS-IS / S5 OSPF / S6 SitN failover"
        echo "  qos          — S7 QoS contention"
        echo "  table        — reprint last result table from raw.csv"
        echo ""
        echo "Results written to: ${RESULTS_DIR}/<timestamp>/"
        ;;
esac
