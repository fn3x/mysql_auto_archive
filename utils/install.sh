# Latest version can be identifed at https://github.com/github/gh-ost/releases/latest
cd /tmp
[ -z "${GHOST_VERSION}" ] && GHOST_VERSION="20231207144046"
wget https://github.com/github/gh-ost/releases/download/v1.1.6/gh-ost-binary-linux-amd64-${GHOST_VERSION}.tar.gz
tar xvfz gh-ost-binary-linux-amd64-${GHOST_VERSION}.tar.gz
file gh-ost
sudo mv gh-ost /usr/local/bin
