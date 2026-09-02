FROM debian:sid
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      devscripts mmdebstrap libstring-shellquote-perl libfile-homedir-perl \
      python3-requests python3-debian python3-apt apt-utils ca-certificates curl equivs dpkg-dev \
      build-essential sbuild uidmap gpgv debian-archive-keyring >/dev/null
