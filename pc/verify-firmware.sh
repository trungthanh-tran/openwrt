#!/bin/sh
# Verify a downloaded firmware image against its published SHA-256 digest.
set -eu
[ "$#" -eq 2 ] || { echo "Usage: $0 <firmware.bin> <expected-sha256>" >&2; exit 2; }
file="$1"
expected="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
[ -f "$file" ] || { echo "File not found: $file" >&2; exit 1; }
# GNU coreutils prefixes a backslash when the displayed filename needs escaping.
actual="$(sha256sum "$file" | awk '{print $1}' | sed 's/^\\//')"
[ "$actual" = "$expected" ] || { printf 'SHA-256 mismatch\nExpected: %s\nActual:   %s\n' "$expected" "$actual" >&2; exit 1; }
printf 'SHA-256 verified: %s\n' "$actual"
