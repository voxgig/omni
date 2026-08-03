.PHONY: build test clean inspect

build:
	npm install --no-audit --no-fund --silent
	npm run build

test: build
	npm test

clean:
	rm -rf dist node_modules

inspect:
	@node --version
	@npx tsc --version
