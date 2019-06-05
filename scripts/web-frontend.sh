#!/bin/bash

set -eou pipefail

if [ -f ../bldr.env ]; then
  source ../bldr.env
elif [ -f /vagrant/bldr.env ]; then
  source /vagrant/bldr.env
else
  echo "ERROR: bldr.env file is missing!"
  exit 1
fi

sudo () {
    [[ $EUID = 0 ]] || set -- command sudo -E "$@"
    "$@"
}

init_haproxy() {
  mkdir -p /hab/user/haproxy-front/config
  cat <<EOT > /hab/user/haproxy-front/config/user.toml
enable_ssl = true
certificate_path = "/etc/ssl/all.pem"

[[servers]]
name = "hab-store"
domain = "hab-store.icts.uiowa.edu"
backend_host = "127.0.0.1"
backend_port = 8888

EOT
}

start_haproxy() {
  sudo hab svc load chrisortman/haproxy-front --force
}

init_haproxy
start_haproxy
