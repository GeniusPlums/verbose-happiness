#!/bin/bash

# Enable error handling
set -e
set -o pipefail

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function for error handling
handle_error() {
    local exit_code=$?
    log "An error occurred on line $1 with exit code $exit_code"
    exit $exit_code
}

# Set up error handling
trap 'handle_error $LINENO' ERR

# Ensure SENTRY_RELEASE exists
if [ ! -f SENTRY_RELEASE ]; then
    log "Creating default SENTRY_RELEASE file"
    echo "development" > SENTRY_RELEASE
fi
export SENTRY_RELEASE=$(cat SENTRY_RELEASE)

# Verify migrations directory exists
if [ ! -d "./migrations" ]; then
    log "Error: migrations directory not found"
    exit 1
fi

# Check required environment variables
log "Checking required environment variables..."
: "${CLICKHOUSE_HOST:=ckai3ao0ad.ap-south-1.aws.clickhouse.cloud}"
: "${CLICKHOUSE_PORT:=8443}"
: "${CLICKHOUSE_USER:=default}"
: "${CLICKHOUSE_DB:=default}"

if [ -z "${CLICKHOUSE_PASSWORD}" ]; then
    log "Warning: CLICKHOUSE_PASSWORD not set, using default value"
fi

# Run ClickHouse migrations with better error handling
log "Running ClickHouse migrations..."
if ! clickhouse-migrations migrate \
    --host "$CLICKHOUSE_HOST" \
    --port "$CLICKHOUSE_PORT" \
    --user "$CLICKHOUSE_USER" \
    --password "${CLICKHOUSE_PASSWORD:-~MG~gu62c6lFW}" \
    --db "$CLICKHOUSE_DB" \
    --migrations-home ./migrations; then
    log "Error: ClickHouse migrations failed"
    exit 1
fi

# Run TypeORM migrations
log "Running TypeORM migrations..."
if ! NODE_OPTIONS="" npx typeorm migration:run -d /app/typeorm.config.cjs; then
    log "Error: TypeORM migrations failed"
    exit 1
fi

# Process type handling with validation
log "Setting up process type..."
case "$1" in
    'web'|'')
        export LAUDSPEAKER_PROCESS_TYPE=WEB
        if [ -f ./scripts/setup_config.sh ]; then
            bash ./scripts/setup_config.sh
        else
            log "Warning: setup_config.sh not found"
        fi
        ;;
    'queue')
        export LAUDSPEAKER_PROCESS_TYPE=QUEUE
        unset SERVE_CLIENT_FROM_NEST
        ;;
    'cron')
        export LAUDSPEAKER_PROCESS_TYPE=CRON
        unset SERVE_CLIENT_FROM_NEST
        ;;
    *)
        log "Error: Invalid process type '$1'"
        exit 1
        ;;
esac

log "Starting LaudSpeaker Process: $LAUDSPEAKER_PROCESS_TYPE"

# Verify the main application file exists
if [ ! -f dist/src/main.js ]; then
    log "Error: Application entry point not found at dist/src/main.js"
    exit 1
fi

# Start the application
exec node dist/src/main.js
