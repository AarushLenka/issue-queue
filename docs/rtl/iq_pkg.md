# `iq_pkg.sv` — Issue Queue Package Reference

The `iq_pkg` package acts as the central configurations and definitions manager for the entire Issue Queue. By centralizing parameters, data structures, and helper functions in this package, we ensure that every module operates on consistent data definitions, avoiding type mismatches and synchronization bugs.

---

## 1. Parameters (Configuration Variables)

These parameters define the sizing and structure of the issue queue. They are set as default constants but can be overridden by parent modules or testbenches.

| Parameter | Type | Default Value | Description / Purpose |
| :--- | :--- | :--- | :--- |
| **`TAG_WIDTH`** | `int unsigned` | `6` | **Tag/Nametag Bit Width.** The number of bits used to represent instruction register tags (or destination identifiers). A width of 6 bits allows the queue to uniquely identify up to $2^6 = 64$ distinct in-flight destination registers. |
| **`NUM_SRC`** | `int unsigned` | `2` | **Number of Source Inputs.** The maximum number of input operands (operands to read) required by a single instruction before it can be executed. By default, it is set to `2` (representing common source registers like `rs1` and `rs2` in RISC architectures). |
| **`DEPTH`** | `int unsigned` | `16` | **Queue Capacity.** The total number of physical slots (entries) inside the Issue Queue. A depth of 16 means the queue can hold up to 16 instructions waiting for execution. |
| **`NUM_PORTS`** | `int unsigned` | `2` | **Execution Ports.** The number of instructions that can be issued (sent to execution units) simultaneously in a single clock cycle. A value of 2 represents a dual-issue processor. |
| **`AGE_WIDTH`** | `int unsigned` | *Derived* | **Age Counter Bit Width.** The number of bits used for the age counters. It scales dynamically with queue `DEPTH` to prevent quick saturation:<br>• `DEPTH <= 16`: `4` bits (max age 15)<br>• `DEPTH <= 256`: `8` bits (max age 255)<br>• Else: `12` bits (max age 4095) |
| **`AGE_SAT_MAX`** | `logic [AGE_WIDTH-1:0]` | `'1` | **Maximum Saturated Age.** A local parameter (all bits set to `1`) representing the maximum value the age counter can reach. Once reached, the counter ceases to increment to prevent overflow wrap-around (which would make a very old instruction look brand new). |

---

## 2. Structure: `iq_entry_t`

The `iq_entry_t` struct is the packed record containing the complete state of a single instruction slot in the issue queue.

```systemverilog
typedef struct packed {
  logic [TAG_WIDTH-1:0]              dst_tag;
  logic [NUM_SRC-1:0][TAG_WIDTH-1:0] src_tag;
  logic [NUM_SRC-1:0]                src_ready;
  logic                              valid;
  logic [AGE_WIDTH-1:0]              age;
  logic [15:0]                       disp_seq;
} iq_entry_t;
```

### Struct Field Breakdown

1. **`dst_tag` (Size: `TAG_WIDTH` bits)**
   - **What it does:** Stores the destination register "nametag" of this instruction. 
   - **Why it is here:** When this instruction eventually issues, runs, and finishes, its `dst_tag` will be broadcast on the global wakeup bus so that other instructions waiting for this value can mark their source inputs as ready.

2. **`src_tag` (Size: `NUM_SRC` operands $\times$ `TAG_WIDTH` bits)**
   - **What it does:** An array of register "nametags" that represent the inputs this instruction needs before it can run.
   - **Why it is here:** The entry compares these tags against the global wakeup broadcast bus to see if a completing instruction is producing one of its required inputs.

3. **`src_ready` (Size: `NUM_SRC` bits)**
   - **What it does:** A bitmask where bit `i` is set to `1` if source input `i` is ready (either because the value was already available at dispatch, was bypassed, or has been woken up).
   - **Why it is here:** The entry cannot issue until all bits in this field are `1`.

4. **`valid` (Size: `1` bit)**
   - **What it does:** Indicates whether this physical slot in the queue currently contains an active instruction (`1` = active/occupied, `0` = free/empty).
   - **Why it is here:** Prevents the selector from issuing garbage data from empty slots and tells the allocator which slots are available for new instructions.

5. **`age` (Size: `AGE_WIDTH` bits)**
   - **What it does:** A counter tracking how long an instruction has been sitting in the queue waiting to run. It starts at `0` on dispatch and increments by `1` every clock cycle.
   - **Why it is here:** Used by the selector to implement age-based priority (picking the oldest ready instructions first to prevent liveness lockups or starvation).

6. **`disp_seq` (Size: `16` bits)**
   - **What it does:** A unique "ticket number" assigned to the instruction when it is dispatched. The number increments monotonically for every instruction accepted.
   - **Why it is here:** Essential during branch misprediction flushes (squashes). If a branch mispredicts, the control unit announces the branch's ticket number (`squash_seq`). Every slot whose `disp_seq` is strictly greater than `squash_seq` was dispatched after the branch and must be instantly flushed.

---

## 3. Helper Functions

### Function: `age_older_than`
```systemverilog
function automatic logic age_older_than(input logic [AGE_WIDTH-1:0] a,
                                         input logic [AGE_WIDTH-1:0] b);
  return (a > b);
endfunction
```
- **Inputs:** Two age values `a` and `b`.
- **Output:** A single bit. Returns `1` if candidate `a` has a larger counter than `b` (meaning `a` has been waiting longer and is therefore older).

### Function: `is_ready`
```systemverilog
function automatic logic is_ready(input iq_entry_t e);
  return e.valid & (&e.src_ready);
endfunction
```
- **Inputs:** An `iq_entry_t` struct representing an entry's state.
- **Output:** A single bit. Returns `1` if the entry is active (`e.valid` is `1`) **AND** all source operands are ready (`&e.src_ready` is `1`, indicating every bit in the mask is set to `1`).

---

## 4. How it Connects to Other Files

Because `iq_pkg` is a package, it does not synthesize into physical wires. Instead, it defines types and functions imported by other files:

- **`iq_if.sv`**: Imports types to define the output port widths of the issue bus (`issue_age` matches `iq_pkg::AGE_WIDTH`).
- **`iq_entry.sv`**: Uses `iq_pkg::iq_entry_t` for internal register storage (`entry_r`) and references `iq_pkg::is_ready` and `iq_pkg::AGE_SAT_MAX`.
- **`iq_wakeup_cam.sv`**: Uses `iq_entry_t` as an array type for its outputs to pass them to the selector.
- **`iq_select.sv`**: Uses `iq_pkg::iq_entry_t` inputs to inspect the age and valid states of all entries. Calls `iq_pkg::age_older_than` to run the tournament brackets.
- **`iq_top.sv`**: Declares intermediate arrays of `iq_pkg::iq_entry_t` to connect the output of the CAM to the input of the selector.
