#!/usr/bin/env bash
set -eu

command -v nvim >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: Neovim is required for the regression tests' >&2
  exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-commit-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT INT TERM
work_dir="$test_dir/repo"
mkdir -p "$work_dir" "$test_dir/home" "$test_dir/state" "$test_dir/data"

command git -c init.templateDir= -C "$work_dir" init -q
command git -C "$work_dir" config user.name Test
command git -C "$work_dir" config user.email test@example.invalid
command git -C "$work_dir" config commit.gpgsign false
for line in {1..120}; do
  printf 'line %s\n' "$line"
done >"$work_dir/tracked.txt"
command git -C "$work_dir" add tracked.txt
command git -C "$work_dir" commit -q -m 'test: baseline'

perl -pi -e 'if ($. == 10) { s/$/ first-change/ } if ($. == 100) { s/$/ second-change/ }' "$work_dir/tracked.txt"

NVIM_AI_COMMIT_TEST=1 \
  LOCAL_CONFIG_TEST_ROOT="$repo_root" \
  AI_COMMIT_TEST_REPO="$work_dir" \
  HOME="$test_dir/home" \
  XDG_STATE_HOME="$test_dir/state" \
  XDG_DATA_HOME="$test_dir/data" \
  command nvim -u NONE -i NONE --headless -l "$repo_root/tests/ai-commit.lua"

NVIM_AI_COMMIT_TEST=1 \
  LOCAL_CONFIG_TEST_ROOT="$repo_root" \
  AI_COMMIT_TEST_REPO="$work_dir" \
  HOME="$test_dir/home" \
  XDG_STATE_HOME="$test_dir/state" \
  XDG_DATA_HOME="$test_dir/data" \
  command nvim -u NONE -i NONE --headless -l "$repo_root/tests/execution.lua"
