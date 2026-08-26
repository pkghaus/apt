# apt.pkg.haus

APT archive for [pkg.haus](https://pkg.haus) packages: current upstream
releases, built from source for Debian stable, testing and unstable, on amd64
and arm64.

## Using the archive

Fetch the signing keyring, then add the source - pick the suite matching your
system (`trixie`, `testing` or `unstable`):

```sh
sudo curl -fsSL -o /usr/share/keyrings/pkghaus-archive-keyring.gpg \
    https://apt.pkg.haus/pkghaus-archive-keyring.gpg

sudo tee /etc/apt/sources.list.d/pkghaus.sources > /dev/null <<EOF
Types: deb
URIs: https://apt.pkg.haus
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/pkghaus-archive-keyring.gpg
EOF

sudo apt update
sudo apt install pkghaus-archive-keyring <package>
```

`pkghaus-archive-keyring` takes over the manually fetched trust anchor:
key rotations then arrive as ordinary signed package updates, with no
further manual step.

## Versioning

One upstream release is built three times - once per suite, against that
suite's libraries - so the version carries a suite qualifier instead of the
filename:

| Suite | Example version |
| --- | --- |
| stable (trixie) | `0.23.3-1~haus13+1` |
| testing | `0.23.3-1~testing1` |
| unstable | `0.23.3-1` |

The qualifiers order below the plain version (`~haus13+1 < ~testing1 <
0.23.3-1`), so upgrading your system from stable towards unstable upgrades
these packages rather than fighting them. `~haus` is this archive's own token,
shaped after Debian's `~bpo` backports convention but deliberately not squatting
it - these packages do not come from Debian backports, and the token doubles as
provenance in `dpkg -l`.

The archive carries one version per package per suite: the newest tag of each
packaging repository. Older versions are rebuildable from their tags but not
retained.

## How it works

- `repos.txt` lists the packaging repositories. Each holds a `debian/`
  directory and a `package.conf`, and is built by
  [action-debian-build](https://github.com/pkghaus/action-debian-build)'s
  builder images.
- Each validated release triggers the
  [ingest](.github/workflows/ingest.yml), which compares the repository's
  newest tag against the archive, builds only what is missing (natively per
  architecture, no emulation), and includes it into an
  [aptly](https://www.aptly.info/) repository. Each build leg checks the
  packaging repository out at its tag and runs the same action a packaging
  repository runs on its own tags, so a package that ships `debian/tests/` has
  those tests run here too. That matters: the archive builds a tag whenever it
  first needs it, sometimes weeks later, against whatever testing and unstable
  have become since.
- Published pool files are immutable: the plan only ever adds missing
  versions, and a version already in the archive is never rebuilt.
- `dists/` and `pool/` are objects in an R2 bucket, served through a Cloudflare
  Worker. The human-facing tree - the pool's listing pages, the news log, the
  keyring - lives on the [`archive`](../../tree/archive) branch and is served
  by GitHub Pages. Both answer under `apt.pkg.haus`.
- aptly's database lives on the [`aptly`](../../tree/aptly) branch. Its package
  pool does not: at the bucket's root prefix aptly only reads a package file it
  cannot already find published, so each run keeps just what it built.

## The archive Worker

`worker/` is `pkghaus-archive`: `pool/` and `dists/` are objects in an R2
bucket that only it can read, so it is what makes apt.pkg.haus an archive
rather than a bucket. It also writes the download counters, because it is the
one point every download passes through.

It lives here rather than alongside the page that displays those counters
because this is the repository that owns the archive: the same pipeline that
publishes objects to the bucket deploys the thing that serves them.

The `/stats` page is a separate Worker in
[pkghaus/stats](https://github.com/pkghaus/stats), reading the same database
on a more specific route. Writer here, reader there, so a bad deploy of a page
cannot take the archive down.

```sh
cd worker && npm ci && npm test
```

## License

```
Copyright 2026 pkg.haus

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## Buy us a coffee?

If you feel like buying us a coffee (or a beer?), donations are welcome:

```
BTC : bc1qq04jnuqqavpccfptmddqjkg7cuspy3new4sxq9
DOGE: DRBkryyau5CMxpBzVmrBAjK6dVdMZSBsuS
ETH : 0x2238A11856428b72E80D70Be8666729497059d95
LTC : MQwXsBrArLRHQzwQZAjJPNrxGS1uNDDKX6
```
