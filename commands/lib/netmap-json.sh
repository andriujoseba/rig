#!/usr/bin/env bash
# jq-free readers for the small tailscale netmap fields bootstrap needs.
# Sourced by bootstrap; never executed on its own.

# json_field <file> <key> — the first string value for <key>, empty if absent.
json_field() {
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
    | head -n1 | sed 's/.*:[[:space:]]*"//; s/"$//' || true
}

# json_string_array <file> <key> — elements of Self.<key>, one per line.
# Self is brace-counted so nested objects do not truncate the search. This
# intentionally stays jq-free because a freshly bootstrapped box has no jq.
json_string_array() {
  local self
  self="$(tr -d '\n' < "$1" 2>/dev/null | awk '
    {
      i = index($0, "\"Self\"")
      if (i == 0) exit
      s = substr($0, i)
      j = index(s, "{")
      if (j == 0) exit
      depth = 0
      for (k = j; k <= length(s); k++) {
        c = substr(s, k, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print substr(s, j, k - j + 1); exit } }
      }
    }')" || true
  [ -n "$self" ] || return 0
  printf '%s' "$self" \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\[[^]]*\]" \
    | head -n1 | grep -o '"[^"]*"' | sed '1d; s/^"//; s/"$//' || true
}
