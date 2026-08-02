CXX ?= g++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -O2

.PHONY: build test clean inspect

build:
	mkdir -p build
	$(CXX) $(CXXFLAGS) -o build/omnitest test/run.cpp

test: build
	./build/omnitest

clean:
	rm -rf build

inspect:
	@$(CXX) --version | head -1
