.PHONY: build test clean inspect

build:
	mkdir -p build
	javac -d build src/com/voxgig/omni/*.java test/*.java

test: build
	java -cp build FibTest

clean:
	rm -rf build

inspect:
	@javac -version 2>&1 | tail -1
