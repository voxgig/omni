.PHONY: build test clean inspect

export DOTNET_CLI_TELEMETRY_OPTOUT = 1
export DOTNET_NOLOGO = 1

build:
	dotnet build test -v q --nologo
	# The struct compat shim is a separate project, so `build test` does not
	# reach it. Building it here keeps it compiled by `make test` - and so by
	# CI - rather than only when a consumer happens to reference it.
	dotnet build compat -v q --nologo

# NOTE: run the built binary rather than `dotnet run`, which forwards its
# own trailing flags to the program as arguments.
test: build
	./test/bin/Debug/net8.0/omnitest

clean:
	rm -rf src/bin src/obj test/bin test/obj compat/bin compat/obj

inspect:
	@dotnet --version
