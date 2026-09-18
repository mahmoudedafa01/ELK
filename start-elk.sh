#!/bin/bash
# ==========================================================
# ELK Stack Startup Script with Readiness Check
# ==========================================================
# Credentials are deliberately NOT stored in this repository.
# Provide them through an untracked env file (chmod 600):
#
#   /work/ELK/.elk-env
#     export ES_USER=elastic
#     export ES_PASSWORD='...'
#
# See README.md in this directory.
# ==========================================================

ELK_ENV_FILE="${ELK_ENV_FILE:-/work/ELK/.elk-env}"
if [ -f "$ELK_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ELK_ENV_FILE"
fi

if [ -z "$ES_USER" ] || [ -z "$ES_PASSWORD" ]; then
    echo "ERROR: ES_USER / ES_PASSWORD are not set. Create $ELK_ENV_FILE first." >&2
    exit 1
fi

echo "1. Starting Elasticsearch service..."
sudo systemctl start elasticsearch-cdrs.service 2>/dev/null || systemctl start elasticsearch-cdrs.service 2>/dev/null

echo "Waiting for Elasticsearch to be fully ready on port 9200..."
until curl -k -u "${ES_USER}:${ES_PASSWORD}" -s https://127.0.0.1:9200 >/dev/null 2>&1; do
    echo "  Elasticsearch is still starting up... sleeping 3 seconds..."
    sleep 3
done

echo "Elasticsearch is READY!"

echo "2. Starting Logstash service..."
sudo systemctl start logstash-cdrs.service 2>/dev/null || systemctl start logstash-cdrs.service 2>/dev/null

echo "3. Starting Filebeat service..."
sudo systemctl start filebeat-cdrs.service 2>/dev/null || systemctl start filebeat-cdrs.service 2>/dev/null

echo "4. Starting Kibana service..."
sudo systemctl start kibana-cdrs.service 2>/dev/null || systemctl start kibana-cdrs.service 2>/dev/null

echo "All services started successfully in correct order!"
