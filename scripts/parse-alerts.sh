#!/bin/bash
LOG_DIR="/var/log/runsc"

limactl shell podman -- sudo tail -F ${LOG_DIR}/*.log 2>/dev/null | \
while IFS= read -r line; do
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if echo "$line" | grep -qE 'openat.*(/etc/passwd|/etc/shadow|id_rsa|\.aws|\.ssh)'; then
    FILE=$(echo "$line" | grep -oE '"[^"]*"' | head -1)
    echo "{\"time\":\"$TIMESTAMP\",\"priority\":\"CRITICAL\",\"rule\":\"Credential read attempt\",\"detail\":$FILE}"

  elif echo "$line" | grep -qE 'execve.*(\"sh\"|\"bash\"|\"zsh\")'; then
    echo "{\"time\":\"$TIMESTAMP\",\"priority\":\"CRITICAL\",\"rule\":\"Shell spawned in container\",\"detail\":\"shell execution detected\"}"

  elif echo "$line" | grep -qE 'connect.*SOCK_STREAM'; then
    echo "{\"time\":\"$TIMESTAMP\",\"priority\":\"WARNING\",\"rule\":\"Outbound network connection\",\"detail\":\"TCP connect attempt\"}"

  elif echo "$line" | grep -qE 'openat.*/proc/[0-9]+/environ'; then
    echo "{\"time\":\"$TIMESTAMP\",\"priority\":\"CRITICAL\",\"rule\":\"Env var exfiltration\",\"detail\":\"/proc/environ access\"}"
  fi
done
