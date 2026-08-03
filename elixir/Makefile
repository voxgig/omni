.PHONY: build test clean inspect

build:
	mkdir -p build
	elixirc -o build lib/*.ex

test: build
	elixir -pa build test/run.exs

clean:
	rm -rf build

inspect:
	@elixir --version | tail -1
