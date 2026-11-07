#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_ONLY=false
case "${1:-}" in
    "") ;;
    --setup-only) SETUP_ONLY=true ;;
    --help)
        echo "Usage: bash scripts/startapp-devcontainer.sh [--setup-only]"
        echo "Installs and starts local PostgreSQL/RabbitMQ, then runs both apps."
        echo "Ctrl+C stops the apps but leaves the shared services running."
        exit 0
        ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
if (( $# > 1 )); then
    echo "Only one argument is supported. Use --help for usage." >&2
    exit 2
fi

fail() { echo "Error: $*" >&2; exit 1; }
trap 'echo "Startup failed at line $LINENO. See the command output above." >&2' ERR

as_root() {
    if (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

as_postgres() {
    as_root runuser -u postgres -- "$@"
}

[[ "$(uname -s)" == Linux && -s /etc/apt/sources.list ]] || fail "This script requires the repository's Debian devcontainer."
command -v apt-get >/dev/null || fail "apt-get is required to install the local services."
if (( EUID != 0 )); then
    command -v sudo >/dev/null || fail "sudo is required to manage the local services."
fi

mkdir -p "$PROJECT_ROOT/logs"
exec 9>"$PROJECT_ROOT/logs/devcontainer.lock"
flock -n 9 || fail "Another devcontainer startup script is already running."

packages=()
command -v psql >/dev/null && command -v pg_isready >/dev/null || packages+=(postgresql)
[[ -x /usr/sbin/rabbitmq-diagnostics ]] || packages+=(rabbitmq-server)
command -v curl >/dev/null || packages+=(curl)
if (( ${#packages[@]} )); then
    echo "Installing missing packages: ${packages[*]}"
    # Use the base image's signed Debian repositories, not unrelated third-party feeds.
    (
        apt_sources="$(mktemp /tmp/asset-manager-apt.XXXXXX.list)"
        trap 'rm -f "$apt_sources"' EXIT
        # Bullseye security packages have moved to Debian's official archive.
        sed '/bullseye-security/ s|http[s]*://deb.debian.org/debian-security|https://archive.debian.org/debian-security|' \
            /etc/apt/sources.list >"$apt_sources"
        chmod 644 "$apt_sources"
        apt_options=(-o "Dir::Etc::sourcelist=$apt_sources" -o Dir::Etc::sourceparts=-)
        as_root apt-get "${apt_options[@]}" update
        as_root env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y "${packages[@]}"
    )
fi

echo "Starting PostgreSQL..."
as_root service postgresql start
postgres_ready=false
for (( attempt=0; attempt<60; attempt++ )); do
    if pg_isready -h localhost -p 5432 >/dev/null; then
        postgres_ready=true
        break
    fi
    sleep 1
done
$postgres_ready || fail "PostgreSQL did not become ready on localhost:5432."

# Only create our development role/database when absent; do not reset existing accounts.
as_postgres psql -p 5432 -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE ROLE assets_dev LOGIN PASSWORD ''assets_dev'''
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'assets_dev')
\gexec
SELECT 'CREATE DATABASE assets_manager OWNER assets_dev'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'assets_manager')
\gexec
SQL

export SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/assets_manager
export SPRING_DATASOURCE_USERNAME=assets_dev
export SPRING_DATASOURCE_PASSWORD="${ASSET_MANAGER_DB_PASSWORD:-assets_dev}"
if ! PGPASSWORD="$SPRING_DATASOURCE_PASSWORD" psql -h localhost -p 5432 \
    -U assets_dev -d assets_manager -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null; then
    fail "Database login failed. If assets_dev already exists, set ASSET_MANAGER_DB_PASSWORD to its password."
fi

echo "Starting RabbitMQ..."
as_root service rabbitmq-server start
rabbit_ready=false
for (( attempt=0; attempt<60; attempt++ )); do
    if as_root /usr/sbin/rabbitmq-diagnostics -q check_running >/dev/null 2>&1 \
        && as_root /usr/sbin/rabbitmq-diagnostics -q check_port_connectivity >/dev/null 2>&1; then
        rabbit_ready=true
        break
    fi
    sleep 1
done
if ! $rabbit_ready; then
    as_root /usr/sbin/rabbitmq-diagnostics status
    fail "RabbitMQ did not become ready. Check /var/log/rabbitmq."
fi
export SPRING_RABBITMQ_HOST=localhost
export SPRING_RABBITMQ_PORT=5672
export SPRING_RABBITMQ_USERNAME=guest
export SPRING_RABBITMQ_PASSWORD=guest
echo "PostgreSQL and RabbitMQ are ready."
$SETUP_ONLY && exit 0

if [[ -n "${ASSET_MANAGER_JAVA_HOME:-}" ]]; then
    export JAVA_HOME="$ASSET_MANAGER_JAVA_HOME"
else
    for candidate in /usr/local/sdkman/candidates/java/* "$HOME"/.jdk/* /usr/lib/jvm/*; do
        if [[ -f "$candidate/release" ]] && grep -q '^JAVA_VERSION="1\.8\.' "$candidate/release"; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
    [[ -x "$JAVA_HOME/bin/java" && -x "$JAVA_HOME/bin/javac" ]] || fail "JAVA_HOME is not a valid JDK: $JAVA_HOME"
    export PATH="$JAVA_HOME/bin:$PATH"
fi
command -v javac >/dev/null || fail "A JDK is required. Rebuild the devcontainer to install JDK 8 alongside JDK 21."
java -version

if (echo >/dev/tcp/localhost/8080) 2>/dev/null; then
    fail "Port 8080 is already in use. Stop the existing server before starting another."
fi

echo "Building both modules..."
cd "$PROJECT_ROOT"
./mvnw -B -DskipTests clean package
shopt -s nullglob
web_jars=("$PROJECT_ROOT"/web/target/*.jar)
worker_jars=("$PROJECT_ROOT"/worker/target/*.jar)
(( ${#web_jars[@]} == 1 && ${#worker_jars[@]} == 1 )) || fail "Expected one executable JAR per module."

app_pids=()
cleanup() {
    local status=$?
    trap - EXIT
    for pid in "${app_pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid"; fi
    done
    for pid in "${app_pids[@]}"; do
        if wait "$pid"; then :; fi
    done
    echo "Java apps stopped. PostgreSQL and RabbitMQ were left running."
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_app() {
    local pid="$1" name="$2" log="$3" ready=false
    for (( attempt=0; attempt<120; attempt++ )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            tail -n 80 "$log" >&2
            fail "$name exited during startup."
        fi
        if grep -q "Started $name " "$log"; then
            ready=true
            break
        fi
        sleep 1
    done
    if ! $ready; then
        tail -n 80 "$log" >&2
        fail "$name did not finish startup within 120 seconds."
    fi
}

echo "Starting web module..."
java -jar "${web_jars[0]}" --spring.profiles.active=dev \
    "--local.storage.directory=$PROJECT_ROOT/storage" >"$PROJECT_ROOT/logs/web.log" 2>&1 &
app_pids+=("$!")
wait_for_app "${app_pids[0]}" AssetsManagerApplication "$PROJECT_ROOT/logs/web.log"
curl --fail --location --silent --show-error --max-time 10 http://localhost:8080/ >/dev/null

# Start sequentially so both modules do not race to create the database schema.
echo "Starting worker module..."
java -jar "${worker_jars[0]}" --spring.profiles.active=dev \
    "--local.storage.directory=$PROJECT_ROOT/storage" >"$PROJECT_ROOT/logs/worker.log" 2>&1 &
app_pids+=("$!")
wait_for_app "${app_pids[1]}" WorkerApplication "$PROJECT_ROOT/logs/worker.log"

echo "Both apps are running. Web application: http://localhost:8080"
echo "Logs: $PROJECT_ROOT/logs/web.log and $PROJECT_ROOT/logs/worker.log"
echo "Keep this terminal open. Press Ctrl+C to stop both apps."
if wait -n "${app_pids[@]}"; then
    fail "An application stopped unexpectedly. Check the logs."
else
    fail "An application failed. Check the logs."
fi
