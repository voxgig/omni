.PHONY: build test clean inspect

# ONE SCALA, SHARED WITH voxgig/sekreto. This port's build output is READ by
# other repositories - sekreto's scala port compiles against it, and struct's
# hands these sources to scala-cli - so the compiler that writes it has to be
# one they can read. TASTy is versioned and forward-INcompatible: a 3.9.0
# build of this tree makes sekreto fail with "Forward incompatible TASTy file
# has version 28.9 ... expected stable TASTy from 28.0 to 28.4", in sekreto,
# about a file it does not own. So the version is PINNED here and in CI, and
# it is the same version sekreto pins (SCALA_VERSION in both ci.yml files).
#
# `scalac` from PATH, and the runtime jars from wherever that scalac lives -
# the same discovery sekreto and struct use, so a distribution unpacked
# anywhere works and no path is written twice.
SCALAC ?= scalac

SCALAHOME := $(shell \
  bin=$$(command -v $(SCALAC)) || exit 0; \
  cd "$$(dirname "$$(readlink -f "$$bin")")/.." && pwd)

SCALAJARS := $(wildcard $(SCALAHOME)/lib/scala3-library_3-*.jar) \
             $(wildcard $(SCALAHOME)/lib/scala-library-*.jar)

empty :=
space := $(empty) $(empty)
SCALACP := $(subst $(space),:,$(strip $(SCALAJARS)))

build:
	mkdir -p build
	$(SCALAC) -d build src/*.scala test/*.scala

# `java -cp`, not `scala run`: the runner CLI only exists in 3.5+, so using it
# would silently require a NEWER scala than the one this port pins - which is
# how the two repositories drifted apart in the first place.
test: build
	@test -n "$(SCALACP)" || { \
	  echo "omni: no scala runtime jars beside $(SCALAC) - is a full scala3 distribution on PATH?" >&2; \
	  exit 1; }
	java -cp build:$(SCALACP) voxgig.omni.test.Main

clean:
	rm -rf build

inspect:
	@$(SCALAC) -version 2>&1 | tail -1
	@echo "runtime jars: $(SCALAJARS)"
