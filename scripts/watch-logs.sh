#!/bin/bash
limactl shell podman -- sudo bash -c \
  'touch /var/log/runsc/current.log && tail -F /var/log/runsc/current.log' \
  | grep --line-buffered -E 'openat|connect|execve' \
  | sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g'
