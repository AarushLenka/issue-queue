# Graph Report - issue-queue  (2026-07-17)

## Corpus Check
- 18 files · ~20,697 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 93 nodes · 76 edges · 19 communities (13 shown, 6 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `086b679b`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- tb_iq_entry.sv
- tb_iq_wakeup_cam.sv
- tb_iq_top_directed.sv
- tb_iq_select.sv
- iq_top
- iq_select
- iq_entry.sv
- iq_wakeup_cam.sv
- CLAUDE.md — Issue Queue (RTL Design Project)
- Build order — follow these steps in sequence, don't skip ahead
- tb_iq_top_random.sv
- graphify.md
- graphify.md
- README.md
- iq_assertions.sv
- How to Simulate

## God Nodes (most connected - your core abstractions)
1. `Build order — follow these steps in sequence, don't skip ahead` - 11 edges
2. `CLAUDE.md — Issue Queue (RTL Design Project)` - 10 edges
3. `Out-of-Order Parametric Issue Queue (IQ)` - 7 edges
4. `Deep Dive: Key Microarchitectural Mechanisms` - 4 edges
5. `Verification Strategy` - 4 edges
6. `How to Simulate` - 4 edges
7. `iq_select` - 3 edges
8. `iq_top` - 3 edges
9. `tb_iq_top_random` - 2 edges
10. `What this project is` - 2 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Import Cycles
- 1-file cycle: `tb/tb_iq_entry.sv -> tb/tb_iq_entry.sv`
- 1-file cycle: `tb/tb_iq_select.sv -> tb/tb_iq_select.sv`
- 1-file cycle: `tb/tb_iq_top_directed.sv -> tb/tb_iq_top_directed.sv`
- 1-file cycle: `tb/tb_iq_top_random.sv -> tb/tb_iq_top_random.sv`
- 1-file cycle: `tb/tb_iq_wakeup_cam.sv -> tb/tb_iq_wakeup_cam.sv`

## Communities (19 total, 6 thin omitted)

### Community 0 - "tb_iq_entry.sv"
Cohesion: 0.29
Nodes (6): do_dispatch_pulse, do_issue_pulse, do_reset, do_wakeup_pulse, iq_pkg, test_basic

### Community 1 - "tb_iq_wakeup_cam.sv"
Cohesion: 0.29
Nodes (6): dispatch_to_slot, do_issue, do_reset, do_wakeup, iq_pkg, test_broadcast

### Community 2 - "tb_iq_top_directed.sv"
Cohesion: 0.29
Nodes (6): do_dispatch, do_reset, do_spec_wakeup, do_wakeup, iq_pkg, tick

### Community 3 - "tb_iq_select.sv"
Cohesion: 0.40
Nodes (3): clear_all, iq_pkg, test_oldest_wins

### Community 4 - "iq_top"
Cohesion: 0.50
Nodes (3): iq_select, iq_wakeup_cam, iq_top

### Community 11 - "CLAUDE.md — Issue Queue (RTL Design Project)"
Cohesion: 0.18
Nodes (10): CLAUDE.md — Issue Queue (RTL Design Project), Commenting standard — this is the most important instruction in this file, Environment, Folder structure (create this first if it doesn't exist), Git conventions (run these directly), `.gitignore` — create this immediately, What this project is, When I ask questions mid-build (+2 more)

### Community 12 - "Build order — follow these steps in sequence, don't skip ahead"
Cohesion: 0.18
Nodes (11): Build order — follow these steps in sequence, don't skip ahead, Step 0 — Package and interface skeleton, Step 1 — Single entry storage (`iq_entry.sv`), Step 2 — Wakeup CAM (`iq_wakeup_cam.sv`), Step 3 — Select logic (`iq_select.sv`) — budget real time here, it's the hardest combinational block, Step 4 — Top-level integration (`iq_top.sv`), Step 5 — Squash/flush interface, Step 6 — Speculative wakeup + replay (stretch — only after Step 5 is solid) (+3 more)

### Community 13 - "tb_iq_top_random.sv"
Cohesion: 0.40
Nodes (4): iq_top, iq_tx, iq_pkg, tb_iq_top_random

### Community 16 - "README.md"
Cohesion: 0.15
Nodes (12): 1. Age-Based Selection, 2. Speculative Wakeup & The Replay Problem, 3. Branch Squashing, Block Diagram, Codebase Architecture, Constrained-Random & Functional Coverage, Deep Dive: Key Microarchitectural Mechanisms, Directed Testing (+4 more)

### Community 18 - "How to Simulate"
Cohesion: 0.50
Nodes (4): 1. Run Directed Tests, 2. Run Constrained-Random Coverage Simulation, 3. Clean Temp Files, How to Simulate

## Knowledge Gaps
- **61 isolated node(s):** `iq_entry`, `iq_wakeup_cam`, `iq_select`, `iq_wakeup_cam`, `iq_assertions` (+56 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Build order — follow these steps in sequence, don't skip ahead` connect `Build order — follow these steps in sequence, don't skip ahead` to `CLAUDE.md — Issue Queue (RTL Design Project)`?**
  _High betweenness centrality (0.037) - this node is a cross-community bridge._
- **Why does `CLAUDE.md — Issue Queue (RTL Design Project)` connect `CLAUDE.md — Issue Queue (RTL Design Project)` to `Build order — follow these steps in sequence, don't skip ahead`?**
  _High betweenness centrality (0.037) - this node is a cross-community bridge._
- **Why does `Out-of-Order Parametric Issue Queue (IQ)` connect `README.md` to `How to Simulate`?**
  _High betweenness centrality (0.024) - this node is a cross-community bridge._
- **What connects `iq_entry`, `iq_wakeup_cam`, `iq_select` to the rest of the system?**
  _61 weakly-connected nodes found - possible documentation gaps or missing edges._