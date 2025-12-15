#!/usr/bin/env bash

echo "--- Local (Internal) IPs ---"
if command -v ip > /dev/null; then
    ip -4 addr show scope global | grep -oP 'inet \K[\d.]+'
else
    ifconfig | grep -Eo 'inet (addr:)?([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}' | grep -v '127.0.0.1'
fi

echo ""
echo "--- External (Public) IPs ---"
if command -v curl > /dev/null; then
    echo -n "IPv4: "
    curl -4 -s ifconfig.me || echo "Unavailable"
    echo ""
    echo -n "IPv6: "
    curl -6 -s checkip.amazonaws.com || echo "Unavailable"
    echo ""
else
    echo "Error: 'curl' is required for public IP check."
fi
