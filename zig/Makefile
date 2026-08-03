.PHONY: build test clean inspect

# Zig 0.16 needs cross-directory imports declared as named modules.
build:
	mkdir -p build
	zig build-exe -femit-bin=build/omnitest \
	  --dep omni -Mroot=test/run.zig -Momni=src/omni.zig

test: build
	./build/omnitest

clean:
	rm -rf build zig-cache .zig-cache zig-out

inspect:
	@zig version
