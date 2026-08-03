.PHONY: build test clean inspect

build:
	mkdir -p build
	ocamlc -I src -I test -o build/omnitest src/omni.ml test/fib.ml test/run.ml
	@rm -f build/*.cmi build/*.cmo src/*.cmi src/*.cmo test/*.cmi test/*.cmo

test: build
	./build/omnitest

clean:
	rm -rf build src/*.cmi src/*.cmo test/*.cmi test/*.cmo

inspect:
	@ocamlc -version
