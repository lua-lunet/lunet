# One-time developer setup lives here. The build guts live in xmake —
# after `make init`, use `xmake build-release`, `xmake test`, `xmake stress`
# (see docs/XMAKE_INTEGRATION.md).

.PHONY: init lint check check-types test help

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

lint:
	xmake lint

check:
	xmake check

check-types:
	xmake check-types

test:
	xmake test

help:
	@echo "Available targets:"
	@echo "  init         - Install system deps + luarocks QA tools + verify the build (default)"
	@echo "  lint         - Run C safety lint checks"
	@echo "  check        - Run luacheck static analysis"
	@echo "  check-types  - Validate LuaCATS annotations with lua-language-server"
	@echo "  test         - Run check-types then the busted suite (xmake test)"
	@echo "  help         - Show this message"
