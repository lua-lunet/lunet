ROOT := $(shell git rev-parse --show-toplevel)

.PHONY: init deps qa-tools verify

init: deps qa-tools verify

deps:
	bash $(ROOT)/contributing/deps/macos.sh

qa-tools:
	bash $(ROOT)/contributing/deps/qa-luarocks.sh

verify:
	cd $(ROOT) && xmake lint && xmake build-release && xmake test
