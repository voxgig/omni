.PHONY: build test clean inspect

build:
	mkdir -p build
	scalac -d build src/*.scala test/*.scala

test: build
	scala run --classpath build --main-class voxgig.omni.test.Main

clean:
	rm -rf build

inspect:
	@scalac -version 2>&1 | tail -1
