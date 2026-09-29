#!/bin/bash
# Paginated preview of the book.
#
# Why this exists instead of just running the CLI on index.html: this working
# tree also contains two large read-only reference checkouts, the `llvm-project`
# symlink (a full LLVM + Linux tree) and `vivliostyle.js/`. Both are gitignored
# and never published, but the CLI's dev server watches the whole project
# directory it resolves, and walking an LLVM checkout exhausts the inotify
# budget:
#
#   Error: ENOSPC: System limit for number of file watchers reached,
#          watch '.../llvm-project/lld/test/COFF/loadcfg-uninitialized.test'
#
# Neither vivliostyle.config.js's vite.server.watch.ignored nor
# --no-enable-static-serve avoids it, and staging inside the repository does not
# either, because the CLI walks up to the nearest vivliostyle.config.js and takes
# that directory as the root. So this stages the book somewhere outside the
# repository and previews from there. The staged copy is exactly what the
# published site contains, so previewing it also checks that nothing outside
# those files is needed.
#
# Usage:  ./preview.sh [host] [port]
#
# SPDX-License-Identifier: CC0-1.0
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
host="${1:-127.0.0.1}"
port="${2:-13000}"
stage="${TMPDIR:-/tmp}/fbvc-preview"

export PATH="$HOME/.local/opt/node22/bin:$PATH"

rm -rf "$stage"
mkdir -p "$stage"
cp "$here/index.html" "$stage/"
cp -r "$here/css" "$here/img" "$stage/"

printf 'staged %s\n' "$stage"
# cd into the stage: the CLI resolves its project root (and therefore what its
# file watcher walks) from the working directory, not from the input path.
cd "$stage"
exec npx -y @vivliostyle/cli@latest preview "$stage/index.html" \
	--no-open-viewer --host "$host" --port "$port"
