#!/usr/bin/env bash
#
# Renders the archive's human-facing pages into the published tree: a
# listing in every directory, the root included, so the tree is browsable
# even though GitHub Pages has no auto-index. Every page shares one
# branded shell (header with the mark, centered column, footer).
#
# Regenerated on every publish, never edited by hand -- like everything
# served, these pages are produced by the ingest. APT clients never read
# them: index.html is not referenced by any Release file. index.html and
# favicon.svg hide themselves from the listings.

set -euo pipefail

ARCHIVE_DIR="${ARCHIVE_DIR:-public}"

STYLE='<style>
  :root {
    --paper: #FFFFFF; --ink: #141414; --muted: #6B6B66;
    --line: #E4E4DF; --accent: #E0421B;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --paper: #0E0E0E; --ink: #F0F0EC; --muted: #8F8F88;
      --line: #2A2A27; --accent: #F0603C;
    }
  }
  * { box-sizing: border-box; }
  body {
    background: var(--paper); color: var(--ink);
    font-family: system-ui, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
    line-height: 1.55; margin: 0; padding: 0 1.25rem 4rem;
  }
  code { font-family: ui-monospace, Menlo, Consolas, monospace; }
  main { max-width: 46rem; margin: 0 auto; }
  header {
    display: flex; align-items: center; gap: 1rem;
    padding: 2.25rem 0 1.25rem; border-bottom: 3px solid var(--ink);
  }
  h1 {
    font-family: ui-monospace, Menlo, Consolas, monospace;
    font-size: clamp(1.9rem, 6vw, 2.6rem); letter-spacing: -.03em;
    margin: 0; line-height: 1.15; min-width: 0;
  }
  h1 .dot, h1 .sep { color: var(--accent); }
  h1 .path { font-size: .65em; }
  h1 .gap { color: var(--muted); }
  h1 a { color: inherit; text-decoration: none; }
  h1 a:hover { color: var(--accent); }
  .tablewrap { overflow-x: auto; padding: 1.5rem 0; }
  table { border-collapse: collapse; width: 100%; font-size: .92rem; }
  th, td { text-align: left; padding: .5rem .75rem .5rem 0; border-bottom: 1px dashed var(--line); }
  th {
    font-family: ui-monospace, Menlo, Consolas, monospace;
    font-size: .7rem; letter-spacing: .12em; text-transform: uppercase;
    color: var(--muted); font-weight: 600;
  }
  td code { font-variant-numeric: tabular-nums; font-size: .85rem; }
  td.size { text-align: right; color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
  th.size { text-align: right; }
  footer {
    border-top: 3px solid var(--ink); padding-top: 1.5rem;
    display: flex; gap: 1.5rem; flex-wrap: wrap;
    font-size: .85rem; color: var(--muted);
  }
  footer a { color: inherit; }
  footer a:hover { color: var(--accent); }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
</style>'

# The mark. Above 48 px the primary cut (fine strokes, serrated tape);
# at or below, the small cut (bold strokes, straight tape) per the brand's
# size ladder.
logo() {
    local size="$1" width tape

    if [ "$size" -gt 48 ]; then
        width=2.4
        tape='M17 15.5 L25 11.5 L47 22.5 L47 28.5 L45.7 27.2 L44.3 29.8 L43 28.5 L41.7 31.2 L40.3 29.8 L39 32.5 L39 26.5 Z'
    else
        width=4.5
        tape='M17 15.5 L25 11.5 L47 22.5 L47 28.5 L39 32.5 L39 26.5 Z'
    fi

    cat <<EOF
    <svg width="$size" height="$size" viewBox="0 0 64 64" role="img" aria-label="pkg.haus - a taped parcel with a haus stenciled on its face">
      <path d="M32 8 L54 19 V45 L32 56 L10 45 V19 Z" fill="var(--paper)"/>
      <g stroke="currentColor" stroke-width="$width" stroke-linejoin="round" stroke-linecap="round" fill="none">
        <path d="M10 19 L32 30 L54 19"/>
        <path d="M32 30 V56"/>
        <path d="M32 8 L54 19 V45 L32 56 L10 45 V19 Z"/>
      </g>
      <path d="$tape" fill="var(--accent)"/>
      <path d="M21 20 L27 26 V33 H15 V26 Z" fill="currentColor" transform="matrix(1,0.5,0,1,0,0)"/>
    </svg>
EOF
}

page_open() {
    local title="$1" heading="$2" logosize="$3"
    cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<script defer src="/zk/js/script.js"></script>
<script>
  window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};
  plausible.init({ endpoint: "/zk/api/event" })
</script>
$STYLE
</head>
<body>
<main>
  <header>
$(logo "$logosize")
    <h1>$heading</h1>
  </header>
EOF
}

page_close() {
    # The stamp ships as UTC (the no-JS fallback) inside a <time> element;
    # the script below reformats it into the visitor's own timezone at view
    # time, so it stays correct even on edge-cached copies.
    cat <<EOF
  <footer>
    <a href="https://pkg.haus">pkg.haus</a>
    <a href="https://github.com/pkghaus">github.com/pkghaus</a>
    <span>rendered by the ingest,
    <time datetime="$(date -u +%Y-%m-%dT%H:%M:%SZ)">$(date -u '+%Y-%m-%d %H:%M:%S UTC')</time></span>
    <span>Apache-2.0</span>
  </footer>
</main>
<script>
  document.querySelectorAll("time[datetime]").forEach(function (t) {
    t.textContent = new Date(t.getAttribute("datetime")).toLocaleString([], {
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
      hour12: false, timeZoneName: "short"
    });
  });
</script>
</body>
</html>
EOF
}

render_favicon() {
    cat > "$ARCHIVE_DIR/favicon.svg" <<'EOF_ICON'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="16" height="16">
  <path d="M32 6 L56 18 V46 L32 58 L8 46 V18 Z" fill="#FFFFFF"/>
  <g stroke="#101010" stroke-width="7" stroke-linejoin="round" stroke-linecap="round" fill="none">
    <path d="M8 18 L32 30 L56 18"/>
    <path d="M32 30 V58"/>
    <path d="M32 6 L56 18 V46 L32 58 L8 46 V18 Z"/>
  </g>
  <path d="M15 14.5 L25 9.5 L49 21.5 L49 28.5 L39 33.5 L39 26.5 Z" fill="#E0421B"/>
</svg>
EOF_ICON
}

# One directory's rows: optional parent link, then directories, then files,
# each sorted; index.html and favicon.svg hide themselves.
listing_rows() {
    local dir="$1" with_parent="$2" entry name size

    if [ "$with_parent" = "parent" ]; then
        echo '      <tr><td><a href="../"><code>../</code></a></td><td class="size">-</td></tr>'
    fi
    for entry in "$dir"/*/; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        printf '      <tr><td><a href="%s/"><code>%s/</code></a></td><td class="size">-</td></tr>\n' \
            "$name" "$name"
    done
    # Root only (the sole noparent caller): the stats page is served by
    # the edge worker (pkghaus/stats), not by a directory in this tree;
    # listed so the archive reads as one service.
    if [ "$with_parent" = "noparent" ]; then
        echo '      <tr><td><a href="/stats"><code>stats/</code></a></td><td class="size">-</td></tr>'
    fi
    for entry in "$dir"/*; do
        [ -f "$entry" ] || continue
        name="$(basename "$entry")"
        case "$name" in index.html|favicon.svg) continue ;; esac
        size="$(stat -c %s "$entry" | numfmt --to=iec)"
        printf '      <tr><td><a href="%s"><code>%s</code></a></td><td class="size">%s</td></tr>\n' \
            "$name" "$name" "$size"
    done
}

listing_table() {
    local dir="$1" with_parent="$2"
    cat <<EOF
  <div class="tablewrap">
    <table>
      <thead>
        <tr><th>name</th><th class="size">size</th></tr>
      </thead>
      <tbody>
$(listing_rows "$dir" "$with_parent")
      </tbody>
    </table>
  </div>
EOF
}

render_root() {
    {
        page_open "apt.pkg.haus" \
            'apt<span class="dot">.</span>pkg<span class="dot">.</span>haus' 80
        listing_table "$ARCHIVE_DIR" noparent
        page_close
    } > "$ARCHIVE_DIR/index.html"
}

render_listings() {
    local dir rel crumbs
    find "$ARCHIVE_DIR" -mindepth 1 -type d -not -path '*/.git*' -print \
        | LC_ALL=C sort | while read -r dir; do
            rel="${dir#"$ARCHIVE_DIR"/}"
            # Breadcrumb: the root name links home at full size; the path
            # rides a smaller tier. Beyond two segments the middle
            # collapses to an ellipsis (../ in the listing still walks
            # up), and <wbr> before each separator lets a pathological
            # segment wrap at a slash instead of clipping.
            depth="$(printf '%s' "$rel" | awk -F/ '{print NF}')"
            if [ "$depth" -le 2 ]; then
                path_html='<span class="sep">/</span>'"$(
                    printf '%s' "$rel" | sed 's|/|<wbr><span class="sep">/</span>|g')"
            else
                path_html='<span class="sep">/</span><span class="gap">&hellip;</span><wbr><span class="sep">/</span>'"${rel##*/}"
            fi
            crumbs='<a href="/">apt<span class="dot">.</span>pkg<span class="dot">.</span>haus</a><span class="path">'"$path_html"'</span>'
            {
                page_open "apt.pkg.haus/$rel/" "$crumbs" 80
                listing_table "$dir" parent
                page_close
            } > "$dir/index.html"
        done
}

render_favicon
render_root
render_listings
echo "rendered root + $(find "$ARCHIVE_DIR" -mindepth 2 -name index.html | wc -l) listings" >&2
