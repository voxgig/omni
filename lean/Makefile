.PHONY: build test clean inspect

# `omnitest` by name: it is no longer a default target, because a
# consumer requiring this port must not be handed omni's self-test exe.
build:
	lake build Omni omnitest

test: build
	./.lake/build/bin/omnitest

clean:
	rm -rf .lake

inspect:
	@lean --version
