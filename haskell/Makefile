.PHONY: build test clean inspect

build:
	mkdir -p build
	ghc -isrc -itest -outputdir build -o build/omnitest test/Run.hs -v0

test: build
	./build/omnitest

clean:
	rm -rf build

inspect:
	@ghc --version
