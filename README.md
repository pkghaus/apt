# apt.pkg.haus

APT archive for [pkg.haus](https://pkg.haus) packages: current upstream
releases, built from source for Debian stable, testing and unstable, on amd64
and arm64.

## Using the archive

Fetch the signing keyring, then add the source — pick the suite matching your
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
sudo apt install <package>
```

## Versioning

One upstream release is built three times — once per suite, against that
suite's libraries — so the version carries a suite qualifier instead of the
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
it — these packages do not come from Debian backports, and the token doubles as
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
  architecture, no emulation), and includes it into a
  [reprepro](https://salsa.debian.org/debian/reprepro) pool.
- Published pool files are immutable — reprepro refuses a different binary
  under an existing version, and the plan only ever adds missing versions.
- The published tree lives on the [`archive`](../../tree/archive) branch and is
  served by GitHub Pages behind `apt.pkg.haus`.

## License

Apache-2.0. See [LICENSE](LICENSE).
