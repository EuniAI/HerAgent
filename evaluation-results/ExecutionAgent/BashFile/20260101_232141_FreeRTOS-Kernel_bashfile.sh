#!/bin/sh
if command -v bash >/dev/null 2>&1; then
  exec /bin/bash /app/prometheus_setup.bash "$@"
else
  if command -v /usr/bin/apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update -y && DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get install -y --no-install-recommends bash; elif command -v dnf >/dev/null 2>&1; then dnf -y install bash; elif command -v yum >/dev/null 2>&1; then yum -y install bash; elif command -v apk >/dev/null 2>&1; then apk add --no-cache bash; fi
  exec /bin/bash /app/prometheus_setup.bash "$@"
fi
