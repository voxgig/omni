.PHONY: build test clean inspect

build:

test:
	PYTHONPATH=.:tests python3 -m unittest discover -s tests -v

clean:
	rm -rf .mypy_cache .ruff_cache **/__pycache__

inspect:
	@python3 --version
