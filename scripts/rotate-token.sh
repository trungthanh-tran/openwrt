#!/bin/sh
# Rotate the local agent bearer token without reinstalling the agent.
set -eu

token_file=/etc/sbproxy/token
if [ "${1:-}" != '--yes' ]; then
  printf 'This immediately invalidates the current UI token. Continue? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) echo 'Cancelled.'; exit 1 ;; esac
fi

mkdir -p /etc/sbproxy
umask 077
tmp="${token_file}.tmp.$$"
trap 'rm -f "$tmp"' EXIT INT TERM
head -c 24 /dev/urandom | hexdump -v -e '/1 "%02x"' > "$tmp"
printf '\n' >> "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$token_file"
trap - EXIT INT TERM
echo 'Agent token rotated. Copy the token below into the local UI:'
cat "$token_file"
