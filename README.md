# FRR SR-MPLS/SRv6 Dual-Plane Backbone Lab

A comprehensive **ContainerLab** network laboratory demonstrating a progressive migration from SR-MPLS to SRv6 in a dual-plane backbone topology using **FRRouting (FRR)**.

## Overview

This lab models a realistic operator environment (based on Ooredoo infrastructure patterns) with two parallel forwarding planes:

- **MPLS Plane**: IPv4 OSPFv2 + SR-MPLS (lower layer)
- **SRv6 Plane**: IPv6 IS-IS + SRv6 (upper layer)

The topology enables coexistence and progressive service migration while validating resilience, convergence, and advanced segment routing features.
<img width="1608" height="1002" alt="backbone_dual_srv6_mpls drawio" src="https://github.com/user-attachments/assets/742645d5-5ce0-4ce8-b51d-6035bd26f167" />

## Architecture

### Topology Components

**Provider Edge Routers (PE)**:
- `pe1-left`, `pe1-right`: SR-MPLS only (OSPF/BGP/LDP)
- `pe2-left`, `pe2-right`: Dual-plane (both SR-MPLS and SRv6)

**Provider Routers (P)**:
- `p{1-4}-mpls`: MPLS plane (OSPF, BGP, LDP) — AS 65000
- `p{1-4}-srv6`: SRv6 plane (IS-IS, BGP with SRv6 locator)

**Customer Edge Routers (CE)**:
- `ce{1-8}`: Static-route-only (no dynamic protocols)

### Forwarding Planes

#### SR-MPLS Plane (Lower)
- **IGP**: OSPFv2
- **Segment Routing**: MPLS labels (SRGB: 16000–23999)
- **Route Reflectors**: `p1-mpls` (10.0.0.21), `p2-mpls` (10.0.0.22)
- **Label format**: 16000 + prefix index (e.g., 10.0.0.21 → label 16021)

#### SRv6 Plane (Upper)
- **IGP**: IS-IS
- **Segment Routing**: SRv6 locators (`fd00:{id}::/48`)
- **Endpoint Behaviors**: End, End.X, End.DT4, End.DT6 (allocated by IS-IS/BGP)

### Services

**L3VPN Configuration**:
- `CUSTOMER-A`: RD/RT `65000:100`
- `CUSTOMER-B`: RD/RT `65000:200`
- Single iBGP AS 65000 with route reflection

## Directory Structure

```
├── configs/                    # Router configurations (bind-mounted into containers)
│   ├── p{1-4}-mpls/           # SR-MPLS plane routers
│   │   ├── frr.conf           # FRR running configuration
│   │   └── daemons            # Daemon control file
│   ├── p{1-4}-srv6/           # SRv6 plane routers
│   │   ├── frr.conf           # FRR running configuration
│   │   └── daemons            # Daemon control file
│   ├── pe{1-2}-{left,right}/  # PE routers
│   │   ├── frr.conf           # FRR running configuration
│   │   └── daemons            # Daemon control file
│   ├── ce{1-8}/               # CE routers (static configs)
│   │   └── frr.conf           # Static CE configuration
│   ├── netshoot/              # Netshoot container configs
│   ├── daemons-mpls           # FRR daemon control (MPLS plane template)
│   ├── daemons-srv6           # FRR daemon control (SRv6 plane template)
│   ├── mpls-init.sh           # MPLS kernel sysctl initialization
│   └── Makefile               # Build/deploy helpers
├── mpls_srv6.clab.yml         # ContainerLab topology definition
├── mpls_srv6.clab.yml.annotations.json  # Visual diagram annotations
├── addresses                  # IP addressing reference guide
├── .gitignore                 # Git ignore patterns (excludes runtime dirs)
└── README.md                  # This file
```

## Addressing Conventions

| Resource | Pattern | Example |
|----------|---------|---------|
| IPv4 loopback | `10.0.0.{id}/32` | pe1-left → `10.0.0.1`, p1-mpls → `10.0.0.21` |
| IPv6 loopback | `fd00::{id}/128` | pe2-left → `fd00::2`, p1-srv6 → `fd00::11` |
| SR-MPLS label | `16000 + loopback last octet` | `10.0.0.21` → label 16021 |
| SRv6 locator | `fd00:{id}::/48` | `fd00::2` → `fd00:2::/48` |
| IS-IS NET | `49.0001.0000.0000.00{zeropad id}.00` | p1-srv6 → `49.0001.0000.0000.0011.00` |
| MPLS P2P links | `172.16.{link}.{1,2}/30` | p1↔p2 → `172.16.2.0/30` |
| SRv6 P2P links | `2001:db8:{link}::/64` | - |
| CE-PE links | `192.168.{x}.{1,2}/30` | - |

## Key Features

- ✅ **Dual-plane coexistence**: SR-MPLS and SRv6 running simultaneously
- ✅ **L3VPN with eBGP stub ASNs**: Multi-customer service separation

## Quick Start

### Prerequisites
- Docker
- ContainerLab
- FRR
- Linux kernel with MPLS and SRv6 support

### Deploy the Lab
```bash
sudo clab deploy -t mpls_srv6.clab.yml --reconfigure 
```

### Access Routers
```bash
# Enter vtysh CLI
docker exec -it clab-dual-plane-backbone-p1-mpls vtysh

# Run single show command
docker exec clab-dual-plane-backbone-p1-mpls vtysh -c "show ip ospf neighbor"
```

### Access Configurations

Router configurations are stored in `configs/<router>/frr.conf` and bind-mounted into containers at startup. Edit these files to persist configuration changes across container restarts.

### Tear Down
```bash
sudo clab destroy -t mpls_srv6.clab.yml
```

## Verification Commands

### SR-MPLS Plane
```
show ip ospf neighbor              # OSPF adjacencies
show ip ospf database              # LSA database
show mpls ldp neighbor             # LDP sessions
show ip route                      # IPv4 routing table
show mpls table                    # MPLS label table
show bgp ipv4 vpn summary          # VPN routes (iBGP)
```

### SRv6 Plane
```
show isis neighbor                 # IS-IS adjacencies
show isis database detail          # LSP database
show ipv6 route                    # IPv6 routing table
show segment-routing srv6 locator  # SRv6 locators & SIDs
show segment-routing srv6 sid     # SRv6 SID information on PE2-left
show bgp ipv6 vpn summary          # VPN routes (iBGP)
```

See [sr_mpls_verification.md](sr_mpls_verification.md) and [srv6_verification.md](srv6_verification.md) for detailed verification procedures.

## KPIs & Validation

**Priority monitoring metrics**:
1. **Data plane**: Latency, jitter, packet loss
2. **IGP**: Convergence time (SPF recalculation)

## Configuration Management

All router configurations are stored in `configs/<router>/frr.conf` and bind-mounted into containers. Edit these files directly to persist changes.

**Key points**:
- Each router has a corresponding directory under `configs/`
- FRR daemon control files (`daemons`) specify which protocols to run
- MPLS kernel sysctls are set in `mpls-init.sh` and applied on container start
- SRv6 sysctls are configured in the ContainerLab topology file (`.clab.yml`)

## NetBox Integration

Import topology and live IPAM state:
```bash
~/netbox-venv/bin/python import_to_netbox.py    # Topology import
~/netbox-venv/bin/python ipam_to_netbox.py      # Live IPAM
```

NetBox runs at `http://localhost:8888`.

## References

- FRR Documentation: https://docs.frrouting.org/
- SR-MPLS: RFC 8660, RFC 8665
- SRv6: RFC 8986, RFC 8987, RFC 9256
- Segment Routing: https://www.segment-routing.net/
- ContainerLab: https://containerlab.dev/
