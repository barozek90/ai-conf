#!/usr/bin/env bash
# Blokuje flagi, które zamieniają "read-only" narzędzia w exec, oraz podstawienia komend.
cmd=$(jq -r '.tool_input.command // empty')
deny_re='(--upload-pack|--receive-pack|--pre[= ]|--pre-glob|--post-renderer|--ext-diff|--open-files-in-pager| -O[^ ]*|-exec\b|-execdir|-delete\b|-ok\b|--output=|\bext::|\$\(|`|\beval\b|\bsource\b|^\. )'
if [[ "$cmd" =~ $deny_re ]]; then
  echo "bash-guard: zablokowano niebezpieczny wzorzec w: $cmd" >&2
  exit 2
fi
exit 0

