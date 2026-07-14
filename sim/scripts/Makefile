# =============================================================================
# Makefile — Issue Queue simulation targets (Cadence Xcelium)
# =============================================================================
# Run from the project root:   make -f sim/scripts/Makefile <target>
#
# All targets write logs into sim/logs/ and run from project root so that
# relative paths in filelist.f resolve correctly.
# =============================================================================

# --- Paths (relative to project root) ----------------------------------------
LOG_DIR   := sim/logs
FILELIST  := sim/scripts/filelist.f

# --- Tool flags ---------------------------------------------------------------
XRUN      := xrun
SVFLAGS   := -sv -64bit -access +rwc -incdir rtl -timescale 1ns/1ps
ELAB_ONLY := -elaborate

# =============================================================================
# Targets
# =============================================================================

.PHONY: help elab_pkg sim_entry sim_top_dir sim_top_rand clean

help:
	@echo ""
	@echo "Issue Queue simulation targets (run from project root):"
	@echo "  make -f sim/scripts/Makefile elab_pkg     — Elaborate pkg + interface only"
	@echo "  make -f sim/scripts/Makefile sim_entry     — Step 1: run tb_iq_entry"
	@echo "  make -f sim/scripts/Makefile sim_top_dir   — Step 4: run tb_iq_top_directed"
	@echo "  make -f sim/scripts/Makefile sim_top_rand  — Step 8: run tb_iq_top_random"
	@echo "  make -f sim/scripts/Makefile clean          — Remove sim artifacts"
	@echo ""

# Step 0 checkpoint: elaborate package + interface, no top-level needed
elab_pkg:
	@mkdir -p $(LOG_DIR)
	$(XRUN) $(SVFLAGS) $(ELAB_ONLY) \
	    rtl/iq_pkg.sv rtl/iq_if.sv \
	    -l $(LOG_DIR)/elab_pkg.log

# Step 1: single-entry directed tests
sim_entry:
	@mkdir -p $(LOG_DIR)
	$(XRUN) $(SVFLAGS) \
	    rtl/iq_pkg.sv rtl/iq_entry.sv tb/tb_iq_entry.sv \
	    -top tb_iq_entry \
	    -l $(LOG_DIR)/sim_entry.log

# Step 2: wakeup CAM broadcast tests
sim_wakeup:
	@mkdir -p $(LOG_DIR)
	$(XRUN) $(SVFLAGS) \
	    rtl/iq_pkg.sv rtl/iq_entry.sv rtl/iq_wakeup_cam.sv \
	    tb/tb_iq_wakeup_cam.sv \
	    -top tb_iq_wakeup_cam \
	    -l $(LOG_DIR)/sim_wakeup.log

# Step 3: selector oldest-ready + multi-port tests
sim_select:
	@mkdir -p $(LOG_DIR)
	$(XRUN) $(SVFLAGS) \
	    rtl/iq_pkg.sv rtl/iq_select.sv \
	    tb/tb_iq_select.sv \
	    -top tb_iq_select \
	    -l $(LOG_DIR)/sim_select.log
# Step 4: top-level integration directed tests
sim_top_dir:
	@mkdir -p $(LOG_DIR)
	$(XRUN) $(SVFLAGS) \
	    rtl/iq_pkg.sv rtl/iq_entry.sv rtl/iq_wakeup_cam.sv \
	    rtl/iq_select.sv rtl/iq_top.sv \
	    sva/iq_assertions.sva \
	    tb/tb_iq_top_directed.sv \
	    -top tb_iq_top_directed \
	    -l $(LOG_DIR)/sim_top_dir.log

# Step 8: constrained-random + coverage
sim_top_rand:
	@mkdir -p $(LOG_DIR)
	$(XRUN) $(SVFLAGS) \
	    -f $(FILELIST) tb/tb_iq_top_random.sv \
	    -top tb_iq_top_random \
	    -coverage all -covoverwrite \
	    -l $(LOG_DIR)/sim_top_rand.log

# Cleanup
clean:
	rm -rf xcelium.d INCA_libs *.history *.diag *.key
	rm -f $(LOG_DIR)/*.log
