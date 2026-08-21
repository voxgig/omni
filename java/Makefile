.PHONY: build jar test clean inspect

build:
	mkdir -p build
	javac -d build src/com/voxgig/omni/*.java test/*.java

# A jar of the runner alone (no test classes), for consumers. Maven cannot
# depend on a directory of loose classes, and omni is not published to Maven
# Central - so a consumer points a system-scoped test dependency at this file.
jar: build
	jar cf build/omni.jar -C build com

test: build
	java -cp build FibTest

clean:
	rm -rf build

inspect:
	@javac -version 2>&1 | tail -1
