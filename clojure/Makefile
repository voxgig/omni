.PHONY: build test clean inspect

# `-M:test` because `test` is not in :paths - see deps.edn. A consumer
# resolving this port as a git dependency must not receive omni's own
# self-test namespaces on their classpath.
build:
	clojure -M:test -e "(require 'voxgig.omni.runner 'voxgig.omni.test.main)"

test:
	clojure -M:test -m voxgig.omni.test.main

clean:
	rm -rf .cpcache

inspect:
	@clojure --version
