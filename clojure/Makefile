.PHONY: build test clean inspect

build:
	clojure -M -e "(require 'voxgig.omni.runner 'voxgig.omni.test.main)"

test:
	clojure -M -m voxgig.omni.test.main

clean:
	rm -rf .cpcache

inspect:
	@clojure --version
