# Top-level Makefile for all omni language ports.
#
# Usage:
#   make test          - run tests for every port
#   make test-go       - run tests for one port
#   make build         - build every port
#   make inspect       - show toolchain versions
#   make clean         - clean build artifacts
#   make parity        - check that every port has the canonical API
#   make struct-compat - run voxgig/struct's own suite on omni's runner
#   make spec          - recompile spec/*.json from spec/*.aontu
#   make spec-check    - fail if a committed spec/*.json is stale

# Every port directory. Target names are the directory names, used verbatim
# as `make -C <dir>`. Each port ships at least `test`; `build`, `inspect`
# and `clean` are invoked tolerantly.
LANGS = typescript javascript python ruby php perl lua go rust java csharp kotlin \
        scala clojure c cpp zig swift dart elixir ocaml haskell lean

.PHONY: all test build inspect clean parity struct-compat check spec spec-check

all: test

# ---- per-port targets ----

test-%:
	@echo "======== $* ========"
	@$(MAKE) -C $* test

build-%:
	@echo "======== $* ========"
	@$(MAKE) -C $* build 2>/dev/null || echo "(no build target)"

inspect-%:
	@printf "%-12s " "$*"
	@$(MAKE) -s -C $* inspect 2>/dev/null || echo "(no inspect target)"

clean-%:
	@$(MAKE) -C $* clean 2>/dev/null || true

# ---- aggregate targets ----

test:
	@fail=""; \
	for lang in $(LANGS); do \
	  echo "======== $$lang ========"; \
	  if $(MAKE) -s -C $$lang test; then :; else fail="$$fail $$lang"; fi; \
	  echo ""; \
	done; \
	if [ -n "$$fail" ]; then echo "FAILED:$$fail"; exit 1; fi; \
	echo "all ports passed"

build:
	@for lang in $(LANGS); do $(MAKE) -s build-$$lang; done

inspect:
	@for lang in $(LANGS); do $(MAKE) -s inspect-$$lang; done

clean:
	@for lang in $(LANGS); do $(MAKE) -s clean-$$lang; done

parity:
	@python3 tools/check_parity.py

# spec/*.json are COMMITTED artifacts compiled from spec/*.aontu by
# @voxgig/model. The .aontu files are the source of truth; every port reads
# only the JSON, so no port needs a Node toolchain to run its tests. After
# editing a *.aontu source, run `make spec` and commit the regenerated JSON —
# CI's spec-freshness check fails on a stale artifact.
spec:
	@cd tools && npm install --no-audit --no-fund --silent && npm run --silent build-spec

spec-check:
	@cd tools && npm install --no-audit --no-fund --silent && npm run --silent build-spec-check && npm run --silent check-spec-shape

# Run voxgig/struct's own JavaScript suite with omni's runner swapped in.
# Pass STRUCT=<path> if the struct repo is not a sibling of this one.
struct-compat:
	@tools/struct_compat.sh $(STRUCT)

check: parity test
