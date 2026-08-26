.PHONY: build test clean inspect

# The boru CLI (https://github.com/boru-lang/boru). Point BORU at a specific
# binary if it is not on PATH:  make test BORU=/path/to/boru
BORU ?= boru

build:
	@echo "No build step for boru (the port is interpreted from source)"

# -no-check -no-compile: the bytecode compiler and the static checker each
# still mishandle parts of this module, which is what voxgig/struct's boru
# port records too. The spec corpus is the contract and exercises the port
# purely at runtime.
test:
	$(BORU) run -no-check -no-compile test/main.boru

clean:
	rm -rf .boru

inspect:
	@$(BORU) help | head -1
