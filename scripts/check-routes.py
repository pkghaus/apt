#!/usr/bin/env python3
"""Assert the live Worker routes are exactly the ones the config declares.

    CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ZONE_ID=... \
        scripts/check-routes.py <path/to/wrangler.toml>

Run AFTER `wrangler deploy`, in the same job, with the same token. Three
assertions, and the set comparison runs in both directions on purpose:

1. Every declared route is live and bound to this script. Catches a deploy
   that did not apply what the file says.
2. Every live route bound to this script is declared. Catches the other
   direction, which is the one nobody notices: a route added by hand in the
   dashboard keeps working, so nothing ever complains, and the config quietly
   stops describing production. pkg.haus/zk/* was exactly that for an unknown
   length of time.
3. `request_limit_fail_open` is false on each. Every pkg.haus host is
   AAAA 100::, the discard prefix, so there is nothing to fall open TO: true
   buys a thirty-second hang ending in 504 where false returns an error a
   client can report and retry. It was swept to false across seven routes on
   2026-09-04 and there is no wrangler field for it, so a route created later
   starts at whatever Cloudflare defaults to. This is what stops that being
   noticed a year late.

Why assert instead of trusting the deploy. Cloudflare documents that declared
routes override, and says nothing about what happens to a route the Worker
owns but the config omits. Measured on this account it survives, but a
mechanism nobody documents is not one to build on, and this estate has got
Worker route behaviour wrong twice.

Zero is not a pass. A config with no routes, a token that returns an empty
list, or a script name that matches nothing would all compare equal-and-empty
and report success, so a positive count is asserted first.

One file, copied verbatim into pkghaus/apt, pkghaus/buildinfos,
pkghaus/stats, pkghaus/website, pkghaus/plausible-worker and
pkghaus/reproducible. There is no public home the estate's repos can share
code through; it is small and stable enough for a copy to be the cheaper
trade. Its tests live in pkghaus/reproducible (tests/run.sh, the "deploy-time
route assertion" group); change it there and copy the file to the other five.
"""

import json
import os
import sys
import tomllib
import urllib.error
import urllib.request

API = "https://api.cloudflare.com/client/v4"


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def live_routes(zone, token):
    request = urllib.request.Request(
        f"{API}/zones/{zone}/workers/routes",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        fail(f"the routes API returned HTTP {error.code}: {error.read()[:200]!r}")
    except urllib.error.URLError as error:
        fail(f"cannot reach the routes API: {error.reason}")

    # A token missing Workers Routes gets a 200 with success=false, not a 403,
    # so the status code alone does not say the call worked.
    if not body.get("success"):
        fail("the routes API refused: "
             + "; ".join(e.get("message", "?") for e in body.get("errors", []))
             + " (the token needs zone Workers Routes on this zone)")
    return body["result"]


def problems(script, config_path, declared, routes):
    """Every complaint about this script's routes, as a list of strings.

    Pure: no network, no environment. main() passes what it fetched and the
    tests pass fixtures, so the comparison that decides a deploy is the same
    code either way.
    """
    mine = {r["pattern"]: r for r in routes if r.get("script") == script}

    # Before comparing. Two empty sets are equal, and that is the shape a
    # broken token, a renamed script and a routeless config all take.
    if not declared:
        return [f"{config_path} declares no routes; this check cannot mean anything"]
    if not mine:
        return [f"no live route is bound to {script!r}; the zone has "
                f"{len(routes)} route(s) bound to "
                f"{sorted({r.get('script') for r in routes})}"]

    out = []
    missing = declared - set(mine)
    if missing:
        out.append(f"declared but not live: {sorted(missing)}")

    undeclared = set(mine) - declared
    if undeclared:
        out.append(
            f"live on {script} but absent from {config_path}: {sorted(undeclared)}"
            " -- add them, do not delete them by hand")

    open_routes = sorted(p for p, r in mine.items()
                         if r.get("request_limit_fail_open"))
    if open_routes:
        out.append(
            f"fail-open is ON for {open_routes}. There is nothing to fall open"
            " to: PUT request_limit_fail_open false, sending the WHOLE route"
            " object (pattern and script too) or the route is reassigned")
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    config_path = sys.argv[1]

    token = os.environ.get("CLOUDFLARE_API_TOKEN")
    zone = os.environ.get("CLOUDFLARE_ZONE_ID")
    if not token or not zone:
        fail("CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID are both required")

    with open(config_path, "rb") as handle:
        config = tomllib.load(handle)
    script = config.get("name")
    if not script:
        fail(f"{config_path} declares no name")
    declared = {r["pattern"] for r in config.get("routes", []) if "pattern" in r}

    routes = live_routes(zone, token)
    found = problems(script, config_path, declared, routes)
    if found:
        for problem in found:
            print(f"FAIL: {problem}", file=sys.stderr)
        sys.exit(1)

    mine = sorted(r["pattern"] for r in routes if r.get("script") == script)
    print(f"{script}: {len(mine)} route(s) declared and live, fail-open off on all")
    for pattern in mine:
        print(f"  {pattern}")


if __name__ == "__main__":
    main()
