# CLAUDE.md — Issue Queue (RTL Design Project)

## Who you're working with

I'm a final-year ECE student who has finished Verilog fundamentals and is currently learning SystemVerilog. I'm building this as a portfolio project for RTL design internship/entry-level applications (NVIDIA, Intel, AMD, Marvell-tier). **My primary goal is learning, not just having working code.** I need to be able to explain every design decision in an interview.

## Environment

- I'm currently working **locally** on my own machine, where you have full file and git access. This is where I write and iterate on RTL/testbenches/scripts with your help.
- I do **not** have the Cadence tool suite (Xcelium, JasperGold, Genus, Innovus, SimVision, IMC) locally — those only exist on a college server I access via SSH. I will periodically push this repo (or copy the relevant files) to that server myself to actually run simulation/synthesis/formal, then bring results (logs, reports, waveform screenshots, coverage exports) back into this repo afterward.
- **This means: you can write RTL/TB/SVA/scripts and reason about expected behavior, but you cannot actually run `xrun`, `jaspergold`, `genus`, `innovus`, or view real simulation output — there's no tool access here.** When a step's checkpoint requires actually running something, say so explicitly and tell me what command to run and what output to look for, then wait for me to paste back results (or describe them) before we continue. Don't claim something "passes" or "is proven" — only I can confirm that once I've run it on the server.
- **You do have full git access here — use it.** Run `git init`, `git add`, `git commit`, branch, and tag directly as we complete each step, using the conventions below. I'll handle getting the repo onto the server separately when it's time to run tools there.

## What this project is

A parameterized, age-ordered, out-of-order instruction issue queue (scheduler) — the block in a CPU pipeline that holds decoded-but-not-yet-ready instructions and picks which ready one(s) issue to execution units each cycle. Full technical spec and step-by-step build order below.

### Why this project exists (context, not to re-derive)
Real OoO cores need CAM-based tag wakeup and age-ordered arbitration to avoid starvation. Most student projects hardcode a tiny fixed-size queue; this one is parameterized (depth/ports/operand count) and includes a formally-reasoned-about fairness property, speculative wakeup, and squash/flush — the kind of scope real design teams review.

## Folder structure (create this first if it doesn't exist)

```
issue-queue/
├── rtl/
│   ├── iq_pkg.sv
│   ├── iq_if.sv
│   ├── iq_entry.sv
│   ├── iq_wakeup_cam.sv
│   ├── iq_select.sv
│   └── iq_top.sv
├── tb/
│   ├── tb_iq_entry.sv
│   ├── tb_iq_top_directed.sv
│   └── tb_iq_top_random.sv
├── sva/
│   └── iq_assertions.sva
├── sim/
│   ├── scripts/         (filelist.f, Makefile)
│   └── logs/             (gitignored)
├── docs/
│   ├── waveforms/
│   └── coverage/
├── .gitignore
└── README.md
```

## Commenting standard — this is the most important instruction in this file

**Every RTL, testbench, and SVA file must be commented as if teaching me the concept, not just documenting syntax.** Specifically:

- For every `always_ff`/`always_comb` block: a comment above it explaining *what microarchitectural behavior this implements and why*, not just "sequential logic block."
- For every non-trivial line (bit slicing, priority encoding, a `for`/`generate` loop, any masking/OR-reduction trick): an inline comment explaining what it computes and, where relevant, why it's written this way instead of an alternative.
- For every SystemVerilog language construct I likely haven't used yet (interfaces, modports, structs, `generate`, `assign` inside `interface`, clocking blocks, `bind`, covergroups, constraint blocks) — the **first time** it appears in the codebase, add a short comment block explaining the construct itself, e.g.:
  ```systemverilog
  // WHAT IS A MODPORT: an interface can be viewed differently by different connected modules.
  // dispatch_mp exposes only the signals the dispatch-side logic needs, as directions relative
  // to that module, so the dispatch unit can't accidentally drive a signal it should only read.
  ```
- When making a design decision with real tradeoffs (age-matrix vs. priority-tree select, saturating vs. wrapping age counter, port-priority fairness), add a comment explaining the tradeoff and why you picked this option — I need to be able to defend these choices in an interview.
- Do not over-comment trivial lines (`logic valid;` doesn't need an essay). Calibrate comment density to concept difficulty, not line count.
- After generating any non-trivial block of RTL, give me a short prose explanation in chat (not just in-code comments) of what you just built and why, before moving to the next step. Assume I will ask follow-up questions — don't dump code and move on silently.

## Git conventions (run these directly)

Branch per step: `feature/<short-name>` (e.g. `feature/iq-entry-storage`). Create the branch before starting a step's work, commit as we go within it, merge to `main` with `--no-ff` once the step's checkpoint is met.
Commit message format: `[rtl|tb|sva] short description`, e.g.:
```
[rtl] implement iq_entry storage with age counter
[tb]  directed test: single dependency chain wakeup
[sva] assertion: no entry issues while not ready
```
Tag milestones: `p1-v1.0-functional` (basic dispatch/wakeup/issue works, directed tests pass), `p1-v2.0-verified` (coverage + SVA clean). Only apply the `-verified`/`-functional` style tags once I've confirmed on the server that the relevant checkpoint actually passed — don't tag speculatively based on code that "should" work.

## `.gitignore` — create this immediately

Include: `*.log`, `xcelium.d/`, `*.vdb`, `*.diag`, `INCA_libs/`, `*.history`, `jgproject/`, `*.jdb`, `.jasper_*`, `.DS_Store`, `*.swp`.
Do NOT gitignore: `docs/coverage/*.html` or waveform screenshots — these are evidence I want checked in.

---

## Build order — follow these steps in sequence, don't skip ahead

Work through each step fully (including its checkpoint) before starting the next. At the end of each step, tell me the git commit message to use and stop for me to sync/commit before continuing, unless I say "keep going through step N."

### Step 0 — Package and interface skeleton
Create `iq_pkg.sv`: parameters (`TAG_WIDTH`, `NUM_SRC`, `DEPTH`, `NUM_PORTS`, `AGE_WIDTH`), and a packed struct `iq_entry_t` (dst_tag, src_tag array, src_ready bits, valid, age). Explain the `AGE_WIDTH` sizing decision (saturating vs. wrapping counter) in comments.

Create `iq_if.sv`: a SystemVerilog `interface` with modports `dispatch_mp`, `issue_mp`, `wakeup_mp`. This is likely my first real exposure to interfaces/modports — comment accordingly (see commenting standard above).

Checkpoint: both files elaborate cleanly standalone (`xrun -sv -elaborate`, I'll run this on the server myself unless you have a way to check syntax here).

### Step 1 — Single entry storage (`iq_entry.sv`)
Implement one entry: dispatch write, wakeup snoop (per-source CAM-style tag compare updating `src_ready` bits), age increment, clear on issue/squash. Explicitly reason through and comment on the same-cycle dispatch+wakeup bypass corner case — decide whether a newly dispatched entry needs to catch a wakeup broadcast in the same cycle it's dispatched, and implement/comment your decision either way.

Write `tb_iq_entry.sv`: directed test — dispatch → drive matching wakeup for src 0 → check ready bit rises → drive wakeup for src 1 → check entry fully ready → issue → check valid clears. Comment the testbench too — explain what each check is verifying and why it matters.

### Step 2 — Wakeup CAM (`iq_wakeup_cam.sv`)
Decide and comment on the partition question: does tag-compare logic live centrally in this module, or distributed inside each `iq_entry`? Explain the fan-in cost (O(DEPTH × NUM_SRC × NUM_WAKEUP_BUSES) comparators) and why real designs favor distributed comparators for scalability.

Standalone testbench: verify multiple entries can wake up simultaneously from one broadcast (the "broadcast" property).

### Step 3 — Select logic (`iq_select.sv`) — budget real time here, it's the hardest combinational block
Sub-step 3a: single-port oldest-ready selection. Implement the simple priority-tree comparator approach first. In comments, describe the alternative age-matrix approach (precomputed pairwise "is entry i older than j" matrix, updated only on dispatch/issue) as a documented "why I didn't do this" tradeoff — I want to understand it even if we don't build it.

Sub-step 3b: multi-port mutual exclusion — later ports mask out entries already granted to earlier ports this cycle. Comment on why this makes port ordering non-fair across ports, and why that's usually acceptable (ports typically map to different execution unit types).

Standalone testbench: verify strictly-oldest selection, verify no two ports ever select the same entry, verify correct "no grant" behavior when ready entries < ports.

### Step 4 — Top-level integration (`iq_top.sv`)
Wire entry array + wakeup CAM + select logic together. Add dispatch backpressure and a free-slot allocator (comment on why you chose priority-encoder-over-free-slots vs. a round-robin allocation pointer).

Write `tb_iq_top_directed.sv`: 5–10 directed dependency-chain tests. Get this fully green before Step 5. Tag `p1-v1.0-functional` once passing.

### Step 5 — Squash/flush interface
Add age-threshold squash (invalidate entries dispatched after a mispredicted branch). Work through and comment on the monotonicity problem: the existing per-entry `age` counter resets/saturates and isn't globally monotonic, so squash comparison likely needs a separate dispatch sequence number — reason through this explicitly in comments before implementing.

Directed test: squash mid-flight, verify exactly the right entries clear.

### Step 6 — Speculative wakeup + replay (stretch — only after Step 5 is solid)
Add a speculative wakeup bus (asserted latency-1 cycles after producer issue) and a kill/replay mechanism. If we run low on time, implement speculative wakeup only and comment clearly what replay would require and why we scoped it out — that's a legitimate, honest thing to document, not a failure.

### Step 7 — SVA assertions (`sva/iq_assertions.sva`)
Bind (not inline) assertions into `iq_top`. Implement: no-issue-while-not-ready, no-double-issue (onehot check across ports), bounded-issue liveness check (needs testbench-side dispatch-ID tagging to track a specific entry across cycles — explain this mechanism in comments since it's a non-obvious verification trick).

### Step 8 — Constrained-random testbench + coverage
`tb_iq_top_random.sv`: randomize dispatch rate, dependency graph shape, squash timing. Build covergroups: occupancy histogram, simultaneous-wakeup count, back-to-back same-port issue, squash-while-in-flight. Explain each covergroup bin's purpose in comments — coverage code needs the same "why" treatment as RTL.

Tag `p1-v2.0-verified` once ≥95% functional coverage achieved.

### Step 9 — Documentation
Help me draft `README.md`: block diagram (ASCII is fine, or describe what an image should show), how-to-run section, results table, design-tradeoffs section pulling together all the decisions we commented on throughout (age-matrix vs. priority-tree, fairness caveat, replay scope). This README needs to read like I understand every choice, because I'll be asked about it.

---

## When I ask questions mid-build

If I ask "why did you do X" or "explain this line," treat it as the primary task, not an interruption — stop and explain fully before continuing with any pending code generation. My understanding is the actual deliverable; working RTL is secondary evidence of that understanding.
