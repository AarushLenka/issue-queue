// =============================================================================
// filelist.f — Xcelium compilation file list for the Issue Queue project
// =============================================================================
// Usage:  xrun -f sim/scripts/filelist.f [options]
//
// Order matters: packages/includes first (iq_pkg.sv), then interfaces, then
// modules bottom-up (leaf modules before top), then testbenches last.
// =============================================================================

// --- Package (must elaborate first — every other file imports it) -----------
rtl/iq_pkg.sv

// --- Interface (depends on iq_pkg parameters) ------------------------------
rtl/iq_if.sv

// --- RTL modules (leaf → top order) ----------------------------------------
rtl/iq_entry.sv
// rtl/iq_wakeup_cam.sv   // Step 2
// rtl/iq_select.sv       // Step 3
// rtl/iq_top.sv          // Step 4

// --- Testbenches (uncomment the one you want to run as top) ----------------
// tb/tb_iq_entry.sv           // Step 1: single-entry directed
// tb/tb_iq_top_directed.sv    // Step 4: integration directed
// tb/tb_iq_top_random.sv      // Step 8: constrained-random + coverage
