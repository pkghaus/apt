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
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      devscripts mmdebstrap libstring-shellquote-perl libfile-homedir-perl \
      python3-requests python3-debian python3-apt apt-utils ca-certificates curl equivs dpkg-dev \
      build-essential sbuild uidmap gpgv debian-archive-keyring >/dev/null
