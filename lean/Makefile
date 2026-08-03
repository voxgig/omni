.PHONY: build test clean inspect

build:
	lake build

test: build
	./.lake/build/bin/omnitest

clean:
	rm -rf .lake

inspect:
	@lean --version
