#!/bin/sh
set -eu

cd "$(dirname "$0")"
sudo install -d /usr/local/libexec/harmony-cast /usr/local/bin /usr/local/share/applications
sudo install -m 755 receiver-service /usr/local/libexec/harmony-cast/receiver-service
sudo install -m 755 cast.py /usr/local/libexec/harmony-cast/cast.py
sudo install -m 644 player.py /usr/local/libexec/harmony-cast/player.py
sudo install -m 755 launcher /usr/local/bin/harmony-cast
sudo install -m 644 harmony-cast.desktop /usr/local/share/applications/harmony-cast.desktop
