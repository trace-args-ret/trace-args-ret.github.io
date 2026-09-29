/**
 * Vivliostyle CLI configuration.
 *
 * The book needs almost none of this -- `index.html` plus `css/book.css` is the
 * whole publication -- but the metadata is worth recording in one place, and
 * `entry` keeps `vivliostyle build` and `vivliostyle preview` agreeing on what
 * the publication is when they are run with no argument.
 *
 * Note for anyone running `vivliostyle preview` in this working tree: the
 * repository also holds two large read-only reference checkouts that are
 * gitignored and never published, `llvm-project` (a symlink to a full LLVM +
 * Linux tree) and `vivliostyle.js/`. The CLI's dev server watches the whole
 * project directory, and walking an LLVM checkout exhausts the inotify budget:
 *
 *   Error: ENOSPC: System limit for number of file watchers reached
 *
 * Setting `vite.server.watch.ignored` here does not help, because the CLI
 * creates its watcher before that option is applied. Use `./preview.sh`, which
 * stages just the book into `.preview/` and previews from there.
 *
 * SPDX-License-Identifier: CC0-1.0
 */
export default {
  title: 'Function-Boundary Value Coverage',
  author: 'Yunseong Kim <ysk@kzalloc.com>',
  language: 'en',
  size: 'JIS-B5',
  entry: ['index.html'],
};
