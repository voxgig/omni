.PHONY: build test clean inspect

build:
	swift build

test: build
	./.build/debug/omnitest

clean:
	rm -rf .build

inspect:
	@swift --version | head -1
