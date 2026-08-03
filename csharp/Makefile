.PHONY: build test clean inspect

export DOTNET_CLI_TELEMETRY_OPTOUT = 1
export DOTNET_NOLOGO = 1

build:
	dotnet build test -v q --nologo

# NOTE: run the built binary rather than `dotnet run`, which forwards its
# own trailing flags to the program as arguments.
test: build
	./test/bin/Debug/net8.0/omnitest

clean:
	rm -rf src/bin src/obj test/bin test/obj

inspect:
	@dotnet --version
