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
    --ok: #4A7C3A; --info: #33688C; --chg: #8A6012;
    /* The brand red measures 4.23:1 on white: fine for the mark, the
       dots and headings, which are large text needing 3:1, and short of
       the 4.5:1 small text needs. Small text gets a darker step;
       everything seen at size keeps the brand value. Dark mode passes
       at 5.92:1, so there the two are the same. */
    --accent-text: #CC3B18;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --paper: #0E0E0E; --ink: #F0F0EC; --muted: #8F8F88;
      --line: #2A2A27; --accent: #F0603C;
      --ok: #7FB56F; --info: #7FA8C9; --chg: #D9A853;
      --accent-text: #F0603C;
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
    display: flex; align-items: center; gap: 1rem; flex-wrap: wrap;
    padding: 2.25rem 0 1.25rem; border-bottom: 3px solid var(--ink);
  }
  .tagline { flex-basis: 100%; color: var(--muted); margin: .75rem 0 0; max-width: 38rem; }
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
  th, td { text-align: left; padding: .5rem .75rem .5rem 0; border-bottom: 1px dashed var(--line); vertical-align: top; }
  th {
    font-family: ui-monospace, Menlo, Consolas, monospace;
    font-size: .7rem; letter-spacing: .12em; text-transform: uppercase;
    color: var(--muted); font-weight: 600;
  }
  td code { font-variant-numeric: tabular-nums; font-size: .85rem; }
  td.size { text-align: right; color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
  th.size { text-align: right; }
  td.date {
    font-family: ui-monospace, Menlo, Consolas, monospace;
    font-size: .85rem; color: var(--muted); white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  /* Thin 11px mono in a mid-tone on white reads washed out next to a
     column of accent-coloured package tokens, even at a passing contrast
     ratio; dark mode escapes it because its tokens are light-on-black.
     Weight 600 plus a tint mixed from the state colour itself makes the
     chip a filled label rather than outlined text, in both themes. */
  .chip {
    display: inline-block; font-family: ui-monospace, Menlo, Consolas, monospace;
    font-size: .72rem; font-weight: 600; border: 1px solid var(--line);
    padding: .1rem .5rem; color: var(--muted); white-space: nowrap;
    background: color-mix(in srgb, var(--muted) 8%, var(--paper));
  }
  .chip.added { color: var(--ok); border-color: var(--ok); background: color-mix(in srgb, var(--ok) 12%, var(--paper)); }
  .chip.updated { color: var(--chg); border-color: var(--chg); background: color-mix(in srgb, var(--chg) 12%, var(--paper)); }
  .chip.security { color: var(--accent-text); border-color: var(--accent); background: color-mix(in srgb, var(--accent) 12%, var(--paper)); }
  .chip.notice { color: var(--info); border-color: var(--info); background: color-mix(in srgb, var(--info) 12%, var(--paper)); }
  .pkgs { display: flex; flex-wrap: wrap; gap: .35rem .9rem; margin-top: .35rem; }
  .pkgs code { font-size: .85rem; white-space: nowrap; }
  .pkgs .ver { color: var(--muted); }
  p.rss { color: var(--muted); font-size: .85rem; margin: 1.25rem 0 0; }
  /* Search and the type toggles are injected by the script below, so a
     reader without JavaScript gets the whole log and no dead widgets. */
  .controls { display: none; gap: .6rem; flex-wrap: wrap; align-items: center; margin: 1.5rem 0 .25rem; }
  .controls.on { display: flex; }
  .controls input {
    font: inherit; font-size: .9rem; padding: .35rem .6rem; flex: 1 1 14rem;
    min-width: 0; color: var(--ink); background: var(--paper); border: 1px solid var(--line);
  }
  .controls input:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
  .types { display: flex; gap: .35rem; flex-wrap: wrap; }
  .types button {
    font-family: ui-monospace, Menlo, Consolas, monospace; font-size: .72rem;
    font-weight: 600; padding: .18rem .5rem; border: 1px solid var(--line);
    background: var(--paper); color: var(--muted); cursor: pointer;
  }
  .types button[aria-pressed="true"] {
    color: var(--accent-text); border-color: var(--accent);
    background: color-mix(in srgb, var(--accent) 12%, var(--paper));
  }
  .count { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: .78rem;
    color: var(--muted); margin: .5rem 0 0; }
  .count b { color: var(--ink); }
  .more { display: none; gap: .6rem; align-items: center; flex-wrap: wrap; margin: 1rem 0 0; }
  .more.on { display: flex; }
  .more button {
    font-family: ui-monospace, Menlo, Consolas, monospace; font-size: .78rem;
    color: var(--accent-text); background: none; border: 1px solid var(--line);
    padding: .3rem .8rem; cursor: pointer;
  }
  .more button:hover { border-color: var(--accent); }
  /* Secondary: an escape hatch, not the main action. */
  .more button.all { color: var(--muted); border-color: transparent;
    text-decoration: underline; padding-left: .2rem; }
  .more button.all:hover { color: var(--accent-text); border-color: transparent; }
  .more button.all[hidden] { display: none; }
  .empty { display: none; color: var(--muted); font-size: .9rem; padding: 1.5rem 0; }
  .empty.on { display: block; }
  footer {
    border-top: 3px solid var(--ink); padding-top: 1.5rem;
    display: flex; gap: 1.5rem; flex-wrap: wrap;
    font-size: .85rem; color: var(--muted);
  }
  footer a { color: inherit; }
  footer a:hover { color: var(--accent-text); }
  a { color: var(--accent-text); text-decoration: none; }
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
    local title="$1" heading="$2" logosize="$3" tagline="${4:-}"
    local desc="${5:-Browsable listing of the pkg.haus APT archive.}"
    local extra_head="${6:-}"

    if [ -n "$tagline" ]; then
        tagline='<p class="tagline">'"$tagline"'</p>'
    fi
    cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<meta name="description" content="$desc">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">${extra_head:+
$extra_head}
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
    $tagline
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
    <span>rendered by the ingest
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
        case "$name" in index.html|favicon.svg|404.html) continue ;; esac
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
            'apt<span class="dot">.</span>pkg<span class="dot">.</span>haus' 80 \
            "The signed APT archive behind pkg.haus."
        listing_table "$ARCHIVE_DIR" noparent
        page_close
    } > "$ARCHIVE_DIR/index.html"
}

render_listings() {
    # news/ is excluded: its index.html is the news page (render_news),
    # not a listing. The anchored path keeps a hypothetical pool package
    # named news* listable.
    local dir rel crumbs
    find "$ARCHIVE_DIR" -mindepth 1 -type d -not -path '*/.git*' -not -path '*/.well-known*' \
        -not -path "$ARCHIVE_DIR/news" -not -path "$ARCHIVE_DIR/news/*" -print \
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

render_404() {
    # GitHub Pages serves /404.html for any missing path.
    {
        page_open "apt.pkg.haus" \
            '<a href="/">apt<span class="dot">.</span>pkg<span class="dot">.</span>haus</a>' 80 \
            "The signed APT archive behind pkg.haus."
        cat <<'EOF'
  <div class="tablewrap">
    <p>404. This path is not in the archive.</p>
    <p>Start from the <a href="/">pool listing</a>, the
    <a href="https://pkg.haus">setup instructions</a>, or the
    <a href="/stats">download stats</a>.</p>
  </div>
EOF
        page_close
    } > "$ARCHIVE_DIR/404.html"
}

render_security_txt() {
    # RFC 9116. Expires is computed at render time, so it renews itself
    # with every publish and can never go stale while the archive lives.
    mkdir -p "$ARCHIVE_DIR/.well-known"
    cat > "$ARCHIVE_DIR/.well-known/security.txt" <<EOF
Contact: mailto:security@pkg.haus
Expires: $(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%S.000Z)
Preferred-Languages: en
Canonical: https://apt.pkg.haus/.well-known/security.txt
EOF
}

# One event field out of a news.jsonl line. Fields are written in fixed
# order with no embedded double quotes (scripts/news.sh documents the
# contract), so a plain extraction is exact.
news_field() {
    printf '%s' "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'
}

# name=version pairs -> linked package tokens. The name links into its
# pool directory; retired packages (empty version) render unlinked, since
# the pool directory is gone.
pkg_tokens() {
    local pairs="$1" pair name ver out=""
    [ -n "$pairs" ] || return 0
    for pair in $pairs; do
        name="${pair%%=*}"
        ver="${pair#*=}"
        if [ -n "$ver" ]; then
            out="$out"'<span><a href="/pool/main/'"${name:0:1}"'/'"$name"'/"><code>'"$name"'</code></a> <code class="ver">'"$ver"'</code></span>'
        else
            out="$out"'<span><code>'"$name"'</code></span>'
        fi
    done
    printf '<span class="pkgs">%s</span>' "$out"
}

news_rows() {
    local line ts type title detail pkgs cls names
    LC_ALL=C sort -r "$1" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        ts="$(news_field "$line" ts)"
        type="$(news_field "$line" type)"
        detail="$(news_field "$line" detail)"
        pkgs="$(news_field "$line" pkgs)"
        case "$type" in
            added|updated|security|notice) cls="chip $type" ;;
            *) cls="chip" ;;
        esac
        # data-pkg carries the names only; the filter matches on those
        # plus the row text.
        names="$(printf '%s' "$pkgs" | tr ' ' '\n' | sed 's/=.*//' | tr '\n' ' ')"
        printf '        <tr data-type="%s" data-pkg="%s"><td class="date">%s</td><td><span class="%s">%s</span></td><td>%s%s</td></tr>\n' \
            "$type" "${names% }" "${ts%%T*}" "$cls" "$type" "$detail" "$(pkg_tokens "$pkgs")"
    done
}

xml_escape() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

news_feed() {
    local line ts type title detail pkgs pair pkglist guid
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
<title>pkg.haus archive news</title>
<link>https://apt.pkg.haus/news/</link>
<atom:link href="https://apt.pkg.haus/news/feed.xml" rel="self" type="application/rss+xml"/>
<description>Everything the pkg.haus APT archive has shipped, changed and retired.</description>
<language>en</language>
EOF
    LC_ALL=C sort -r "$1" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        ts="$(news_field "$line" ts)"
        type="$(news_field "$line" type)"
        title="$(news_field "$line" title)"
        detail="$(news_field "$line" detail | sed 's/<[^>]*>//g')"
        pkgs="$(news_field "$line" pkgs)"
        [ -n "$detail" ] || detail="$title"
        if [ -n "$pkgs" ]; then
            pkglist=""
            for pair in $pkgs; do
                pkglist="$pkglist, $(printf '%s' "$pair" | sed 's/=/ /; s/ $//')"
            done
            detail="$detail (${pkglist#, })"
        fi
        # Stable across renders: the date plus the title, slugged.
        guid="$(printf '%s-%s' "${ts%%T*}" "$title" | tr -c 'A-Za-z0-9.\n' '-' | tr -s '-')"
        cat <<EOF
<item>
<title>$(printf '%s' "$title" | xml_escape)</title>
<link>https://apt.pkg.haus/news/</link>
<guid isPermaLink="false">$guid</guid>
<pubDate>$(date -u -R -d "$ts")</pubDate>
<description>$(printf '%s' "$detail" | xml_escape)</description>
</item>
EOF
    done
    printf '</channel>\n</rss>\n'
}

render_news() {
    # The news log lives on the archive branch (news/news.jsonl,
    # maintained by scripts/news.sh before this renderer runs). No log,
    # no page.
    local news="$ARCHIVE_DIR/news/news.jsonl"
    [ -s "$news" ] || return 0

    local crumbs='<a href="/">apt<span class="dot">.</span>pkg<span class="dot">.</span>haus</a><span class="path"><span class="sep">/</span>news</span>'
    {
        page_open "apt.pkg.haus/news/" "$crumbs" 80 \
            "Everything the archive has shipped, changed and retired, newest first." \
            "What the pkg.haus APT archive has shipped, changed and retired." \
            '<link rel="alternate" type="application/rss+xml" title="pkg.haus archive news" href="/news/feed.xml">'
        cat <<'EOF'
  <div class="controls" id="ctl">
    <input id="q" type="search" placeholder="filter by package, for example croc"
           aria-label="Filter by package">
    <span class="types" id="types">
      <button type="button" data-t="added" aria-pressed="false">added</button>
      <button type="button" data-t="updated" aria-pressed="false">updated</button>
      <button type="button" data-t="security" aria-pressed="false">security</button>
      <button type="button" data-t="retired" aria-pressed="false">retired</button>
      <button type="button" data-t="notice" aria-pressed="false">notice</button>
    </span>
  </div>
  <p class="count" id="count"></p>
  <div class="tablewrap">
    <table>
      <thead>
        <tr><th>date</th><th>event</th><th>detail</th></tr>
      </thead>
      <tbody id="log">
EOF
        news_rows "$news"
        cat <<'EOF'
      </tbody>
    </table>
  </div>
  <p class="empty" id="empty">No events match. Clearing the filter shows the whole log.</p>
  <p class="more" id="more"><button type="button" id="olderBtn"></button><button type="button" class="all" id="allBtn" hidden></button></p>
  <p class="rss">Subscribe: <a href="/news/feed.xml">feed.xml</a> (RSS)</p>
<script>
(function () {
  var PAGE = 25;
  var rows = Array.prototype.slice.call(document.querySelectorAll("#log tr"));
  var q = document.getElementById("q");
  var types = document.getElementById("types");
  var count = document.getElementById("count");
  var more = document.getElementById("more");
  var btn = document.getElementById("olderBtn");
  var allBtn = document.getElementById("allBtn");
  var empty = document.getElementById("empty");
  var shown = PAGE;
  var expansions = 0;
  var active = {};

  document.getElementById("ctl").className = "controls on";

  function matches(tr) {
    var t = q.value.trim().toLowerCase();
    var picked = Object.keys(active).filter(function (k) { return active[k]; });
    if (picked.length && picked.indexOf(tr.getAttribute("data-type")) === -1) return false;
    if (!t) return true;
    // Every row, never only the visible ones: a filter that silently
    // skips hidden history is worse than no filter.
    return (tr.getAttribute("data-pkg") + " " + tr.textContent)
      .toLowerCase().indexOf(t) !== -1;
  }

  function draw() {
    var filtering = q.value.trim() !== "" ||
      Object.keys(active).some(function (k) { return active[k]; });
    var hits = 0, drawn = 0;
    rows.forEach(function (tr) {
      var m = matches(tr);
      if (m) hits++;
      // While filtering every match shows: the cap governs browsing,
      // not finding.
      var vis = m && (filtering || drawn < shown);
      if (vis && !filtering) drawn++;
      tr.style.display = vis ? "" : "none";
    });

    empty.className = hits === 0 ? "empty on" : "empty";
    if (filtering) {
      count.innerHTML = "<b>" + hits + "</b> of " + rows.length + " events match";
      more.className = "more";
      return;
    }
    var vis = Math.min(shown, rows.length);
    count.innerHTML = "showing <b>" + vis + "</b> of " + rows.length + " events";
    if (vis < rows.length) {
      var left = rows.length - vis;
      btn.textContent = "show " + Math.min(PAGE, left) + " older";
      // After real intent to dig, and only while a jump saves clicks.
      allBtn.hidden = !(expansions >= 2 && left > PAGE);
      allBtn.textContent = "show all " + rows.length;
      more.className = "more on";
    } else {
      more.className = "more";
    }
  }

  q.addEventListener("input", draw);
  types.addEventListener("click", function (e) {
    var b = e.target.closest("button[data-t]");
    if (!b) return;
    var t = b.getAttribute("data-t");
    active[t] = !active[t];
    b.setAttribute("aria-pressed", active[t] ? "true" : "false");
    draw();
  });
  // Appending only grows the page downward, so nothing above moves.
  btn.addEventListener("click", function () { shown += PAGE; expansions++; draw(); });
  allBtn.addEventListener("click", function () { shown = rows.length; draw(); });

  draw();
})();
</script>
EOF
        page_close
    } > "$ARCHIVE_DIR/news/index.html"

    news_feed "$news" > "$ARCHIVE_DIR/news/feed.xml"
}

render_favicon
render_root
render_listings
render_404
render_security_txt
render_news
echo "rendered root + $(find "$ARCHIVE_DIR" -mindepth 2 -name index.html | wc -l) listings" >&2
