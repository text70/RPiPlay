#!/bin/sh
# Keeps a NoInputNoOutput pairing agent registered and the adapter
# pairable, so new Bluetooth devices can be paired headlessly.
{
	printf 'power on\npairable on\nagent NoInputNoOutput\ndefault-agent\n'
	exec tail -f /dev/null
} | /usr/bin/bluetoothctl
