# Maelstrom test rig for the lunet jsonic demo.
#
#   make build    build both images (classic builder, linux/arm64)
#   make test     build + run the echo workload; exits non-zero on failure
#   make results  copy maelstrom's store/ out of the rig container into
#                 <repo>/.tmp/maelstrom-results-<timestamp>/
#   make clean    tear down compose project and delete the images

PLATFORM   := linux/arm64
DEMO_IMAGE := lunet-jsonic-demo:latest
RIG_IMAGE  := lunet-jsonic-rig:latest
REPO_ROOT  := $(abspath ../../..)
COMPOSE    := docker compose -f docker-compose.yml
TIME_LIMIT ?= 10
NODE_COUNT ?= 1
WORKLOAD   ?= echo

export MAELSTROM_TIME_LIMIT := $(TIME_LIMIT)
export MAELSTROM_NODE_COUNT := $(NODE_COUNT)
export MAELSTROM_WORKLOAD   := $(WORKLOAD)

.PHONY: build test results clean

build:
	DOCKER_BUILDKIT=0 docker build --platform $(PLATFORM) \
	  -f Dockerfile.demo -t $(DEMO_IMAGE) $(REPO_ROOT)
	DOCKER_BUILDKIT=0 docker build --platform $(PLATFORM) \
	  -f Dockerfile.rig -t $(RIG_IMAGE) $(REPO_ROOT)

test: build
	@ts=$$(date +%Y%m%d_%H%M%S); \
	$(COMPOSE) up --abort-on-container-exit --exit-code-from rig; rc=$$?; \
	cid=$$($(COMPOSE) ps -a -q rig); \
	if [ -n "$$cid" ]; then \
	  dest="$(REPO_ROOT)/.tmp/maelstrom-results-$$ts"; \
	  mkdir -p "$$dest"; \
	  docker cp "$$cid:/app/store" "$$dest/store" 2>/dev/null || true; \
	  echo "results in $$dest/store"; \
	fi; \
	$(COMPOSE) down -v; exit $$rc

results:
	@cid=$$($(COMPOSE) ps -a -q rig); \
	if [ -z "$$cid" ]; then echo "no rig container found; run 'docker compose up' first" >&2; exit 1; fi; \
	ts=$$(date +%Y%m%d_%H%M%S); \
	dest="$(REPO_ROOT)/.tmp/maelstrom-results-$$ts"; \
	mkdir -p "$$dest"; \
	docker cp "$$cid:/app/store" "$$dest/store"; \
	echo "results in $$dest/store"

clean:
	-$(COMPOSE) down -v
	-docker rmi $(RIG_IMAGE) $(DEMO_IMAGE)
