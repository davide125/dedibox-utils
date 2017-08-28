# dedibox-utils

Collection of tools to ease setup and management of dedicated servers.

## dedibox-setup
Automate setup of Debian 9 on a Dedibox XC SATA 2016 from online.net. This is
meant to be run from the rescue environment, and will setup LVM over encrypted
root, among other things. Put a `dedibox-setup.conf` in the same directory to
override default settings.

## dedibox-rescue
Wrapper around ssh to get into the online.net rescue environment without having
to worry about key warnings.

## dedibox-unlock
Automate entry of the dm-crypt passphrase to unlock a remote machine.
