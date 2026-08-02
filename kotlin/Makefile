.PHONY: build test clean inspect

build:
	mkdir -p build
	kotlinc src/*.kt test/*.kt -include-runtime -d build/omnitest.jar

test: build
	java -jar build/omnitest.jar

clean:
	rm -rf build

inspect:
	@kotlinc -version 2>&1 | tail -1
