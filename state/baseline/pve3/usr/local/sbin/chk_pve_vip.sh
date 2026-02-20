#!/bin/sh
pidof haproxy  > /dev/null 2>&1 || exit 1
pidof pveproxy > /dev/null 2>&1 || exit 1
exit 0
