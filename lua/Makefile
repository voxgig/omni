.PHONY: build test clean inspect

LUA ?= lua5.4

build:

test:
	$(LUA) test/run.lua && $(LUA) test/ext.lua

clean:

inspect:
	@$(LUA) -v
