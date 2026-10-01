#!/bin/sh
# ELF magic without od/hexdump: \177ELF has no NUL byte, so command
# substitution preserves it and = compares byte-for-byte.
is_elf_new() { [ "$(head -c 4 "$1" 2>/dev/null)" = "$(printf '\177ELF')" ]; }
is_elf_old() { [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; }
printf '\177ELF' > /tmp/real-elf-magic
printf '<html>404</html>' > /tmp/fake404
cp /Users/bayanist/Documents/krot/dist-openflux/openflux-linux-arm64 /tmp/realelf 2>/dev/null
for f in /tmp/realelf /tmp/real-elf-magic /tmp/fake404 /nonexistent; do
  printf '%-40s new=%s old=%s\n' "$f" "$(is_elf_new $f && echo ELF || echo no)" "$(is_elf_old $f && echo ELF || echo no)"
done
