#!/bin/sh

IPADDR="$1"

if [ -r "$PWD/dedibox-setup.conf" ]; then
  echo "using config from $PWD/dedibox-setup.conf"
  . "$PWD/dedibox-setup.conf"
fi

ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no $IPADDR
