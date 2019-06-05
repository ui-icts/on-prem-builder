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

# Defaults
BLDR_ORIGIN=${BLDR_ORIGIN:="habitat"}

sudo () {
    [[ $EUID = 0 ]] || set -- command sudo -E "$@"
    "$@"
}

init_datastore() {
  mkdir -p /hab/user/builder-datastore/config
  cat <<EOT > /hab/user/builder-datastore/config/user.toml
max_locks_per_transaction = 128
dynamic_shared_memory_type = 'none'

[superuser]
name = 'hab'
password = 'hab'
EOT
}

configure() {
  while [ ! -f /hab/svc/builder-datastore/config/pwfile ]
  do
    sleep 2
  done

  export PGPASSWORD
  PGPASSWORD=$(cat /hab/svc/builder-datastore/config/pwfile)

  export ANALYTICS_ENABLED=${ANALYTICS_ENABLED:="false"}
  export ANALYTICS_COMPANY_ID
  export ANALYTICS_COMPANY_NAME
  export ANALYTICS_WRITE_KEY

  if [ $ANALYTICS_ENABLED = "true" ]; then
    ANALYTICS_WRITE_KEY=${ANALYTICS_WRITE_KEY:="NAwVPW04CeESMW3vtyqjJZmVMNBSQ1K1"}
    ANALYTICS_COMPANY_ID=${ANALYTICS_COMPANY_ID:="builder-on-prem"}
  else
    ANALYTICS_WRITE_KEY=""
    ANALYTICS_COMPANY_ID=""
    ANALYTICS_COMPANY_NAME=""
  fi

  mkdir -p /hab/user/builder-minio/config
  cat <<EOT > /hab/user/builder-minio/config/user.toml
key_id = "$MINIO_ACCESS_KEY"
secret_key = "$MINIO_SECRET_KEY"
bucket_name = "$MINIO_BUCKET"
EOT

  mkdir -p /hab/user/builder-api/config
  if [ ${ARTIFACTORY_ENABLED:-false} = "true" ]; then
    FEATURES_ENABLED="ARTIFACTORY"
  else
    FEATURES_ENABLED=""
    ARTIFACTORY_API_URL="http://localhost:8081"
    ARTIFACTORY_API_KEY="none"
    ARTIFACTORY_REPO="habitat-builder-artifact-store"
  fi
  cat <<EOT > /hab/user/builder-api/config/user.toml
log_level="error,tokio_core=error,tokio_reactor=error,zmq=error,hyper=error"
jobsrv_enabled = false

[http]
handler_count = 10

[api]
features_enabled = "$FEATURES_ENABLED"
targets = ["x86_64-linux", "x86_64-linux-kernel2", "x86_64-windows"]

[depot]
jobsrv_enabled = false

[oauth]
provider = "$OAUTH_PROVIDER"
userinfo_url = "$OAUTH_USERINFO_URL"
token_url = "$OAUTH_TOKEN_URL"
redirect_url = "$OAUTH_REDIRECT_URL"
client_id = "$OAUTH_CLIENT_ID"
client_secret = "$OAUTH_CLIENT_SECRET"

[segment]
url = "https://api.segment.io"
write_key = "$ANALYTICS_WRITE_KEY"

[s3]
backend = "minio"
key_id = "$MINIO_ACCESS_KEY"
secret_key = "$MINIO_SECRET_KEY"
endpoint = "$MINIO_ENDPOINT"
bucket_name = "$MINIO_BUCKET"

[artifactory]
api_url = "$ARTIFACTORY_API_URL"
api_key = "$ARTIFACTORY_API_KEY"
repo = "$ARTIFACTORY_REPO"

[memcache]
ttl = 1

[datastore]
password = "$PGPASSWORD"
connection_timeout_sec = 5
EOT

  mkdir -p /hab/user/builder-api-proxy/config
  cat <<EOT > /hab/user/builder-api-proxy/config/user.toml
log_level="info"
enable_builder = false
app_url = "${APP_URL}"

[oauth]
provider = "$OAUTH_PROVIDER"
client_id = "$OAUTH_CLIENT_ID"
authorize_url = "$OAUTH_AUTHORIZE_URL"
redirect_url = "$OAUTH_REDIRECT_URL"

[nginx]
max_body_size = "2048m"
proxy_send_timeout = 180
proxy_read_timeout = 180
enable_gzip = true
enable_caching = true

[http]
keepalive_timeout = "180s"

[server]
listen_tls = $APP_SSL_ENABLED
listen_port               = 8888
listen_tls_port           = 4444

[analytics]
enabled = $ANALYTICS_ENABLED
company_id = "$ANALYTICS_COMPANY_ID"
company_name = "$ANALYTICS_COMPANY_NAME"
write_key = "$ANALYTICS_WRITE_KEY"
EOT
}

start_api() {
  sudo hab svc load "${BLDR_ORIGIN}/builder-api" --bind memcached:builder-memcached.default --bind datastore:builder-datastore.default --channel "${BLDR_CHANNEL}" --force
}

start_api_proxy() {
  sudo hab svc load "${BLDR_ORIGIN}/builder-api-proxy" --bind http:builder-api.default --channel "${BLDR_CHANNEL}" --force
}

start_datastore() {
  sudo hab svc load "${BLDR_ORIGIN}/builder-datastore" --channel "${BLDR_CHANNEL}" --force
}

start_minio() {
  sudo hab svc load "${BLDR_ORIGIN}/builder-minio" --channel "${BLDR_CHANNEL}" --force
}

start_memcached() {
  sudo hab svc load "${BLDR_ORIGIN}/builder-memcached" --channel "${BLDR_CHANNEL}" --force
}

generate_bldr_keys() {
  mapfile -t keys < <(find /hab/cache/keys -name "bldr-*.pub")

  if [ "${#keys[@]}" -gt 0 ]; then
    KEY_NAME=$(echo "${keys[0]}" | grep -Po "bldr-\\d+")
    echo "Re-using existing builder key: $KEY_NAME"
  else
    KEY_NAME=$(hab user key generate bldr | grep -Po "bldr-\\d+")
    echo "Generated new builder key: $KEY_NAME"
  fi

  hab file upload "builder-api.default" "$(date +%s)" "/hab/cache/keys/${KEY_NAME}.pub"
  hab file upload "builder-api.default" "$(date +%s)" "/hab/cache/keys/${KEY_NAME}.box.key"
}

upload_ssl_certificate() {
  if [ ${APP_SSL_ENABLED} = true ]; then
    echo "SSL enabled - uploading certificate files"
    if ! [ -f "../ssl-certificate.crt" ] || ! [ -f "../ssl-certificate.key" ]; then
      pwd
      echo "ERROR: Certificate file(s) not found!"
      exit 1
    fi
    hab file upload "builder-api-proxy.default" "$(date +%s)" "../ssl-certificate.crt"
    hab file upload "builder-api-proxy.default" "$(date +%s)" "../ssl-certificate.key"
  fi
}

start_builder() {
  init_datastore
  start_datastore
  configure
  if ! [ ${ARTIFACTORY_ENABLED:-false} = "true" ]; then
    start_minio
  fi
  start_memcached
  start_api
  start_api_proxy
  sleep 2
  generate_bldr_keys
  upload_ssl_certificate
}

sudo systemctl start hab-sup-default
sleep 2
start_builder
