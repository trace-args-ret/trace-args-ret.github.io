#!/bin/bash
# Render every diagrams/*.mmd to img/<name>.svg.
#
# The book is deliberately script-free: Vivliostyle builds its own DOM from the
# source HTML and never runs page scripts, so Mermaid cannot render at read
# time. Diagrams are therefore rendered ahead of time and committed as SVG.
#
# Requires node and network access on first run (npx fetches mermaid-cli).
# Re-run after editing any .mmd file.
#
# SPDX-License-Identifier: CC0-1.0
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
out="$root/img"

export PATH="$HOME/.local/opt/node22/bin:$PATH"

# Mermaid drives a headless Chrome through puppeteer. Reuse the one Vivliostyle
# already downloaded rather than fetching a second copy.
if [ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ]; then
	chrome="$(find "$HOME/.cache/vivliostyle/browsers" -name chrome -type f 2>/dev/null | head -1)"
	[ -n "$chrome" ] && export PUPPETEER_EXECUTABLE_PATH="$chrome"
fi

mkdir -p "$out"

for src in "$here"/*.mmd; do
	name="$(basename "$src" .mmd)"
	svg="$out/$name.svg"
	printf '%s\n' "$name"
	npx -y @mermaid-js/mermaid-cli@11 \
		-i "$src" -o "$svg" \
		-c "$here/mermaid.json" \
		-b transparent --quiet

	# mermaid emits width="100%", which leaves an <img> without an intrinsic
	# size. Replace it with the viewBox extent so the browser and Vivliostyle
	# both lay the figure out before the SVG is fetched.
	node -e '
	const fs = require("fs");
	const f = process.argv[1];
	let s = fs.readFileSync(f, "utf8");
	const m = s.match(/viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"/);
	if (m) {
	  s = s.replace(/(<svg[^>]*?)\swidth="100%"/,
	                `$1 width="${Math.round(+m[1])}" height="${Math.round(+m[2])}"`);
	  fs.writeFileSync(f, s);
	}' "$svg"
done

printf 'rendered %d diagrams into %s\n' "$(ls -1 "$here"/*.mmd | wc -l)" "$out"
