# One-time developer setup lives here. The build guts live in xmake —
# after `make init`, use `xmake build-release`, `xmake test`, `xmake stress`
# (see docs/XMAKE_INTEGRATION.md).

.PHONY: init help

init:
	@OS=$$(uname -s); \
	case "$$OS" in \
		Darwin) $(MAKE) -f contributing/macos/Makefile init ;; \
		Linux)  \
			if ! command -v apt-get >/dev/null 2>&1; then \
				echo "WARNING: apt-get not found. This Makefile assumes a Debian/Ubuntu host."; \
				echo "Adapt contributing/deps/debian.sh for your distro, or install deps manually."; \
			fi; \
			$(MAKE) -f contributing/debian/Makefile init ;; \
		*) echo "Windows? run: pwsh contributing\\windows\\setup.ps1" ;; \
	esac

help:
	@echo "Available targets:"
	@echo "  init  - Install system deps + luarocks QA tools + verify the build"
	@echo "  help  - Show this message"
	@echo ""
	@echo "Build/test/lint: use xmake directly — xmake lint, xmake check, xmake test, etc."
