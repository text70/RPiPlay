#!/bin/sh
# Keeps the Bluetooth adapter powered, discoverable and pairable, and keeps
# a NoInputNoOutput pairing agent registered, so phones can find and pair
# with the Pi headlessly.
#
# The initial sleep lets bluetoothd finish settling after boot; without it
# the power-on command can race the daemon and silently fail.
sleep 3

{
	printf 'power on\npairable on\ndiscoverable on\ndiscoverable-timeout 0\nagent NoInputNoOutput\ndefault-agent\n'
	exec tail -f /dev/null
} | /usr/bin/bluetoothctl
