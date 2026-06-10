#!/usr/bin/env bash
# scripts/run_tests.sh

set -e

# Create an isolated test environment using XDG variables
TEST_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'packard_tests')
export XDG_DATA_HOME="$TEST_DIR/data"
export XDG_CONFIG_HOME="$TEST_DIR/config"
export XDG_STATE_HOME="$TEST_DIR/state"

# Ensure directories exist
mkdir -p "$XDG_DATA_HOME/nvim/site/pack/core/opt"
mkdir -p "$XDG_CONFIG_HOME/nvim/lua/plugins"
mkdir -p "$XDG_STATE_HOME/nvim"

# Ensure cleanup on exit
trap 'rm -rf "$TEST_DIR"' EXIT

# Add current directory and lua/ to runtimepath so tests can find packard
# We use --cmd to ensure rtp is set before any processing
COMMAND="set rtp+=. | set rtp+=./lua"

# If TESTS is not provided, find all *_spec.lua in tests/
if [ -z "$TESTS" ]; then
  IFS=$'\n' read -r -d '' -a TESTS < <(find tests -name "*_spec.lua" && printf '\0')
fi

FAILED=0

for test in "${TESTS[@]}"; do
  echo "--------------------------------------------------"
  echo "Testing: $test"
  if ! nvim --clean -u NONE --cmd "$COMMAND" -l "$test"; then
    echo "FAILED: $test"
    FAILED=1
  fi
done

echo "--------------------------------------------------"
if [ $FAILED -eq 0 ]; then
  echo "ALL TESTS PASSED!"
  exit 0
else
  echo "SOME TESTS FAILED!"
  exit 1
fi
