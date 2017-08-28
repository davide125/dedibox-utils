#!/bin/sh

BASE="$(dirname "$0")"
HOST="$1"
gpg --decrypt "$BASE"/key-"$HOST".gpg | \
  ssh -o UserKnownHostsFile="$BASE"/known_hosts.initramfs -o BatchMode=yes \
    root@"$HOST" 'cat > /lib/cryptsetup/passfifo'
