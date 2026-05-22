.PHONY: test format lint check

test:
	./scripts/run_tests.sh

format:
	stylua .

lint:
	stylua --check .
	lua-language-server --check .

check:
	lua-language-server --check .
