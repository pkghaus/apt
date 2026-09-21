# The base MUST match the suite of the record being verified, and rebuild.sh
# derives it from the .buildinfo's version qualifier. Pinned to sid here only as
# the default for an unqualified (unstable) record.
#
# Verifying a trixie record from a sid image does not work: debrebuild installs
# the exact versions the record names, so libc6 is DOWNGRADED to trixie's, and
# sid's perl-base is linked against a newer glibc than that provides. On
# 2026-09-08 the transition 2.43-4 -> 2.41-12+deb13u3 left perl unable to load
# POSIX.so ("version `GLIBC_2.42' not found"), which killed every maintainer
# script and failed the run at dependency install. The same downgrade had
# succeeded the day before, so this fails only once sid's glibc has moved far
# enough ahead -- it is a clock-driven break, not a change in the package.
ARG BASE=sid
FROM debian:${BASE}

# snapshot.debian.org is a rate-limited volunteer service, and apt's default
# Acquire::Retries is 0 (apt.conf(5): "If this is non-zero APT will retry
# failed files the given number of times"). A rebuild resolves several hundred
# build dependencies from it, so ONE refused fetch failed the whole run and the
# verdict came out UNKWN with nothing learned. Five retries turns the common
# transient case into a completed comparison.
#
# It changes how apt fetches, never what it installs, so it cannot affect what
# is being verified: the record names exact versions and debrebuild installs
# those or fails.
RUN printf 'Acquire::Retries "5";\n' > /etc/apt/apt.conf.d/80-pkghaus-retries
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      devscripts mmdebstrap libstring-shellquote-perl libfile-homedir-perl \
      python3-requests python3-debian python3-apt apt-utils ca-certificates curl equivs dpkg-dev \
      build-essential sbuild uidmap gpgv debian-archive-keyring >/dev/null
