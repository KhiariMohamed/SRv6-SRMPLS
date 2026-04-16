# =============================================================================
# Makefile — netshoot QoS + benchmark interaction
# Run from your project root on Ubuntu host
# =============================================================================

NS  = clab-dual-plane-backbone-netshoot
PE2 = clab-dual-plane-backbone-pe2-left
IMG = nicolaka/netshoot

.PHONY: help qos-apply qos-show qos-reset qos-verify qos-watch \
        bench bench-latency bench-convergence bench-qos bench-table \
        shell results clean

help:
	@echo ""
	@echo "  QoS commands (run via netshoot inside pe2-left netns)"
	@echo "    make qos-apply       apply HTB QoS on pe2-left eth1"
	@echo "    make qos-show        show qdiscs / classes / filters with counters"
	@echo "    make qos-reset       remove all QoS rules"
	@echo "    make qos-verify      check QoS is correctly installed"
	@echo "    make qos-watch       live counter refresh every 2s"
	@echo ""
	@echo "  Benchmark commands"
	@echo "    make bench           run all 7 scenarios"
	@echo "    make bench-latency   S1 SRv6 + S2 MPLS + S3 cross-plane"
	@echo "    make bench-conv      S4 IS-IS + S5 OSPF + S6 SitN failover"
	@echo "    make bench-qos       S7 QoS contention"
	@echo "    make bench-table     reprint last result table"
	@echo ""
	@echo "  Utilities"
	@echo "    make shell           interactive shell inside netshoot/pe2-left netns"
	@echo "    make results         list result directories"
	@echo "    make clean           remove all results"
	@echo ""

# ── QoS ──────────────────────────────────────────────────────────────────────

qos-apply:
	docker exec $(NS) /etc/netshoot/qos.sh apply

qos-show:
	docker exec $(NS) /etc/netshoot/qos.sh show

qos-reset:
	docker exec $(NS) /etc/netshoot/qos.sh reset

qos-verify:
	docker exec $(NS) /etc/netshoot/qos.sh verify

qos-watch:
	docker exec -it $(NS) /etc/netshoot/qos.sh watch

# ── Benchmarks ───────────────────────────────────────────────────────────────

bench:
	docker exec $(NS) /etc/netshoot/benchmark.sh all

bench-latency:
	docker exec $(NS) /etc/netshoot/benchmark.sh latency

bench-conv:
	docker exec $(NS) /etc/netshoot/benchmark.sh convergence

bench-qos: qos-apply
	docker exec $(NS) /etc/netshoot/benchmark.sh qos

bench-table:
	docker exec $(NS) /etc/netshoot/benchmark.sh table

# ── Utilities ─────────────────────────────────────────────────────────────────

shell:
	docker exec -it $(NS) bash

results:
	@ls -lt results/ 2>/dev/null | head -20 || echo "No results yet"
	@echo ""
	@find results/ -name "raw.csv" 2>/dev/null | \
	  xargs -I{} sh -c 'echo "── {}"; cat {} | column -t -s,'

clean:
	rm -rf results/
	@echo "Results cleared"



# ── sFlow ────────────────────────────────────────────────────────────────────
sflow-topo:
	python3 topo.py clab-dual-plane-backbone

sflow-agents:
	curl -s http://localhost:8008/agents/json | python3 -m json.tool

sflow-flows:
	curl -s "http://localhost:8008/activeflows/ALL/json?maxFlows=20" \
	  | python3 -m json.tool

sflow-metric:
	@read -p "Node IP: " n; read -p "Metric: " m; \
	  curl -s "http://localhost:8008/metric/$$n/$$m/json"

dashboard:
	xdg-open http://localhost:8008
