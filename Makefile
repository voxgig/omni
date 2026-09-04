# Top-level Makefile for all omni language ports.
#
# Usage:
#   make test          - run tests for every port EXCEPT any listed in HOLD
#   make test-go       - run tests for one port
#   make build         - build every port
#   make inspect       - show toolchain versions
#   make clean         - clean build artifacts
#   make parity        - check that every port has the canonical API
#   make struct-compat - run voxgig/struct's own suite on omni's runner
#   make pack-check    - install the npm ports from a tarball and use them
#   make pack-diff     - what a release would add/remove vs the registry
#   make spec          - recompile spec/*.json from spec/*.aon
#   make spec-check    - fail if a committed spec/*.json is stale

# Every port directory. Target names are the directory names, used verbatim
# as `make -C <dir>`. Each port ships at least `test`; `build`, `inspect`
# and `clean` are invoked tolerantly.
ALL_LANGS = typescript javascript python ruby php perl lua go rust java csharp kotlin \
        scala clojure c cpp zig swift dart elixir ocaml haskell lean boru

# PORTS ON HOLD. Dropped from the aggregate targets that run a toolchain --
# test, build, inspect -- and from nothing else. `make test-boru`, `make -C
# boru test`, `clean` and tools/check_parity.py all still reach a held port.
# Emptying this list restores it. voxgig/struct holds the same port for the
# same reason; the two lists are meant to agree.
#
#   boru  The engine has no release channel of ANY kind -- no tags, no
#         published binaries, and `go install` refuses it outright -- so the
#         only reproducible version is a commit built from source, and a
#         binary that does not match fails as a bare `undefined word` that
#         reads as broken source rather than a stale toolchain. The port is
#         also the slowest here by a wide margin: it is interpreted, one
#         corpus entry at a time, with no JIT. Held until boru-lang/boru
#         ships a release.
#
#         CI IS HELD TOO, since 2026-09-04: the `boru` job in
#         .github/workflows/ci.yml now runs only on a manual dispatch,
#         never on a push or a pull request -- the same shape as this
#         list, held from the sweep but still reachable on purpose. That reverses a
#         deliberate choice rather than fixing an oversight -- the job ran
#         precisely so the port could not rot while it waited, and while it
#         is skipped nothing exercises boru against a moving engine.
#         Accepted for the moment. Emptying this list and deleting that
#         `if: false` are the two halves of restoring the port.
#         voxgig/struct holds the same port the same way.
HOLD = boru

LANGS = $(filter-out $(HOLD),$(ALL_LANGS))

.PHONY: all test build inspect clean parity struct-compat pack-check pack-diff check spec spec-check

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

# A HELD PORT IS NAMED IN THE VERDICT, NOT SILENTLY DROPPED. "all ports
# passed" after a sweep that skipped one is how a partial local run gets
# read as full conformance. With HOLD empty this prints exactly what it
# always did.
test:
	@fail=""; \
	for lang in $(LANGS); do \
	  echo "======== $$lang ========"; \
	  if $(MAKE) -s -C $$lang test; then :; else fail="$$fail $$lang"; fi; \
	  echo ""; \
	done; \
	if [ -n "$(HOLD)" ]; then \
	  echo "HELD, NOT RUN: $(HOLD)   (see HOLD in the Makefile)"; \
	fi; \
	if [ -n "$$fail" ]; then echo "FAILED:$$fail"; exit 1; fi; \
	if [ -n "$(HOLD)" ]; then \
	  echo "$(words $(LANGS)) of $(words $(ALL_LANGS)) ports passed"; \
	else \
	  echo "all ports passed"; \
	fi

build:
	@for lang in $(LANGS); do $(MAKE) -s build-$$lang; done

inspect:
	@for lang in $(LANGS); do $(MAKE) -s inspect-$$lang; done

clean:
	@for lang in $(ALL_LANGS); do $(MAKE) -s clean-$$lang; done

parity:
	@python3 tools/check_parity.py

# spec/*.json are COMMITTED artifacts compiled from spec/*.aon by
# @voxgig/model. The .aon files are the source of truth; every port reads
# only the JSON, so no port needs a Node toolchain to run its tests. After
# editing a *.aon source, run `make spec` and commit the regenerated JSON —
# CI's spec-freshness check fails on a stale artifact.
spec:
	@cd tools && npm install --no-audit --no-fund --silent && npm run --silent build-spec

spec-check:
	@cd tools && npm install --no-audit --no-fund --silent && npm run --silent build-spec-check && npm run --silent check-spec-shape

# Run voxgig/struct's own JavaScript suite with omni's runner swapped in.
# Pass STRUCT=<path> if the struct repo is not a sibling of this one.
struct-compat:
	@tools/struct_compat.sh $(STRUCT)

# What the npm ports would actually publish, exercised as a consumer gets
# it: packed, installed into an empty directory outside this repository,
# then used. The suites cannot see this - they run against the working
# tree, where every file is present whatever `files` says.
pack-check:
	@tools/pack_check.sh $(PORTS)

# What a release would add to, or remove from, the published package.
# Needs the network, so it is not part of `check` and not a PR job -
# pack-check is the hermetic one. Removing a file that the published
# version has is how a patch release silently breaks a consumer.
pack-diff:
	@tools/pack_diff.sh $(PORTS)

check: parity test
