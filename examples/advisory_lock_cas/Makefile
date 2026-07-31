REPO_ROOT := $(shell git rev-parse --show-toplevel)
LUNET_BIN := $(shell find $(REPO_ROOT)/build -path '*/release/lunet-run' -type f 2>/dev/null | head -1)

.PHONY: test-e2e test-concurrent test-all test-nc \
	test-ordering test-timeout test-pending test-logs test-clean \
	test-quoting test-validation clean

test-e2e:
	cd $(REPO_ROOT) && LUNET_BIN=$(LUNET_BIN) $(LUNET_BIN) examples/advisory_lock_cas/run_demo.lua

test-concurrent:
	cd $(REPO_ROOT) && LUNET_BIN=$(LUNET_BIN) $(LUNET_BIN) test/item07_concurrent_test.lua

test-ordering:
	cd $(REPO_ROOT) && $(LUNET_BIN) test/item14a_s2_ordering_test.lua

test-timeout:
	cd $(REPO_ROOT) && $(LUNET_BIN) test/item14c_timeout_test.lua

test-pending:
	cd $(REPO_ROOT) && $(LUNET_BIN) test/item14d_pending_table_test.lua

test-logs:
	cd $(REPO_ROOT) && $(LUNET_BIN) test/item14e_logflush_test.lua

test-clean:
	cd $(REPO_ROOT) && $(LUNET_BIN) test/item14f_make_clean_test.lua

test-quoting:
	cd $(REPO_ROOT) && $(LUNET_BIN) test/item14g_mkdir_quote_test.lua

test-validation:
	cd $(REPO_ROOT) && $(LUNET_BIN) test/item14h_holder_zero_test.lua && \
		luajit test/item14i_u32_bounds_test.lua

test-nc:
	cd $(REPO_ROOT) && $(LUNET_BIN) test/item14j_nc_driver_test.lua

test-all: test-e2e test-concurrent test-ordering test-timeout test-pending \
	test-logs test-clean test-quoting test-validation test-nc
	@echo "PASS: all advisory_lock_cas test targets green"

clean:
	rm -f $(REPO_ROOT)/.tmp/advisory_lock_config.lua \
		$(REPO_ROOT)/.tmp/advisory_lock_node_*_ready \
		$(REPO_ROOT)/.tmp/item14*_config.lua \
		$(REPO_ROOT)/.tmp/test_item0*_config.lua
