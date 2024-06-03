#!/bin/bash

# Default configurations for downloading JRE
FEATURE_VERSION=${FEATURE_VERSION:-"11"}
RELEASE_TYPE=${RELEASE_TYPE:-"ga"}
HEAP_SIZE=${HEAP_SIZE:-"normal"}
IMAGE_TYPE=${IMAGE_TYPE:-"jre"}
JVM_IMPL=${JVM_IMPL:-"hotspot"}
PROJECT=${PROJECT:-"jdk"}
VENDOR=${VENDOR:-"eclipse"}

# Number of retries for downloading
MAX_RETRIES=3

# Base directory for JREs
BASE_DIR="jre"

# Function to check if a port is in use
is_port_in_use() {
    local PORT=$1
    netstat -an | grep "$PORT" | grep LISTEN >/dev/null
    return $?
}

# Function to check if the application is ready
wait_for_server() {
    local PORT=$1
    local ENVIRONMENT=$2
    local MAX_ATTEMPTS=60
    local ATTEMPTS=0
    echo "Waiting for $ENVIRONMENT server on port $PORT to be ready..."
    while ! curl --output /dev/null --silent --head --fail http://localhost:"$PORT"; do
        if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
            echo "Timeout reached. $ENVIRONMENT server on port $PORT is not responding."
            exit 1
        fi
        printf '.'
        sleep 2
        ATTEMPTS=$((ATTEMPTS + 1))
    done
    echo "$ENVIRONMENT server on port $PORT is ready!"
}

# Function to check the operating system and architecture
detect_os_arch() {
    local OS
    local ARCH
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$ARCH" in
    x86_64)
        ARCH="x64"
        ;;
    aarch64 | arm64)
        ARCH="aarch64"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac

    case "$OS" in
    linux)
        OS="linux"
        ;;
    darwin)
        OS="mac"
        ;;
    *)
        echo "Unsupported operating system: $OS"
        exit 1
        ;;
    esac

    echo "$OS/$ARCH"
}

# Function to fetch release information without jq
fetch_release_information() {
    local ARCHITECTURE=$1
    local OS=$2
    local RELEASE_URL="https://api.adoptium.net/v3/assets/feature_releases/${FEATURE_VERSION}/${RELEASE_TYPE}?architecture=${ARCHITECTURE}&heap_size=${HEAP_SIZE}&image_type=${IMAGE_TYPE}&jvm_impl=${JVM_IMPL}&os=${OS}&page=0&page_size=1&project=${PROJECT}&sort_method=DEFAULT&sort_order=DESC&vendor=${VENDOR}"

    echo "Release URL for $OS $ARCHITECTURE: $RELEASE_URL"

    local FEATURE_RELEASE_INFORMATION
    if ! FEATURE_RELEASE_INFORMATION=$(curl -s "$RELEASE_URL"); then
        echo "Error: Failed to fetch release information from $RELEASE_URL."
        return 1
    fi

    DOWNLOAD_LINK=$(echo "$FEATURE_RELEASE_INFORMATION" | awk -F '"' '/"link": ".*\.tar\.gz"/ {print $4}' | head -n 1)

    if [ -z "$DOWNLOAD_LINK" ]; then
        echo "Error: Failed to get download link for $OS $ARCHITECTURE."
        return 1
    fi

    return 0
}

# Function to prompt for user confirmation
prompt_confirmation() {
    read -r -p "Do you want to proceed with downloading the JRE for $1? [y/N] " response
    case "$response" in
    [yY][eE][sS] | [yY])
        return 0
        ;;
    *)
        echo "Download aborted by user."
        return 1
        ;;
    esac
}

# Function to download a file with retries
download_file() {
    local URL=$1
    local DEST_DIR=$2
    local RETRY_COUNT=0

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if curl -L -o "$DEST_DIR/$(basename "$URL")" "$URL"; then
            return 0
        fi
        echo "Download failed. Retrying... ($((RETRY_COUNT + 1))/$MAX_RETRIES)"
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 2
    done

    echo "Error: Failed to download file from $URL after $MAX_RETRIES retries."
    return 1
}

# Function to download JRE for a specific platform and architecture
download_jre() {
    local ARCHITECTURE=$1
    local OS=$2
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf -- "$TEMP_DIR"' EXIT

    if ! fetch_release_information "$ARCHITECTURE" "$OS"; then
        echo "Error: Failed to fetch release information for $OS $ARCHITECTURE."
        return 1
    fi

    if ! prompt_confirmation "$OS/$ARCHITECTURE"; then
        return 1
    fi

    echo "Downloading JRE for $OS $ARCHITECTURE..."
    if ! download_file "$DOWNLOAD_LINK" "$TEMP_DIR"; then
        echo "Error: Failed to download JRE for $OS $ARCHITECTURE."
        return 1
    fi

    DEST_DIR="$BASE_DIR/$OS/$ARCHITECTURE"
    mkdir -p "$DEST_DIR"

    tar -xzf "$TEMP_DIR"/*.tar.gz -C "$DEST_DIR" --strip-components=1

    echo "JRE for $OS $ARCHITECTURE download, verification, and extraction complete."
}

# Check Java version
check_installed_java_version() {
    local MIN_VERSION=8
    local MAX_VERSION=15
    local JAVA_VERSION
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    if [[ -z "$JAVA_VERSION" ]]; then
        echo "Java is not installed. Please install Java and try again."
        return 1
    else
        local JAVA_MAJOR_VERSION
        JAVA_MAJOR_VERSION=$(echo "$JAVA_VERSION" | cut -d'.' -f1)
        if [[ "$JAVA_MAJOR_VERSION" == "1" ]]; then
            JAVA_MAJOR_VERSION=$(echo "$JAVA_VERSION" | cut -d'.' -f1-2 | cut -d'.' -f2)
        fi
        echo "Installed Java version: $JAVA_VERSION"
        if ((JAVA_MAJOR_VERSION < MIN_VERSION || JAVA_MAJOR_VERSION > MAX_VERSION)); then
            echo "Installed Java version unsupported: $JAVA_VERSION. Supported versions are: $MIN_VERSION to $MAX_VERSION."
            return 1
        fi
    fi
    return 0
}

# Function to check if JRE is already downloaded
check_jre_downloaded() {
    local OS_ARCH=$1
    local DEST_DIR="$BASE_DIR/$OS_ARCH"
    echo "Directory: $DEST_DIR"
    if [ -d "$DEST_DIR" ]; then
        echo "JRE for $OS_ARCH is already downloaded."
        return 0
    else
        echo "JRE for $OS_ARCH is not downloaded."
        return 1
    fi
}

# Check downloaded JRE version
check_downloaded_jre_version() {
    local OS_ARCH=$1
    local JAVA_VERSION
    JAVA_VERSION=$("$JAVA_HOME/bin/java" -version 2>&1 | awk -F '"' '/version/ {print $2}')
    echo "Downloaded Java version: $JAVA_VERSION"
}

# Check if the contrast_security.yaml file exists
check_config_file() {
    local CONFIG_FILE="$SCRIPT_DIR/contrast_security.yaml"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file '$CONFIG_FILE' not found. Please ensure it is present in the same directory as this script."
        exit 1
    fi
}

# Function to start the application
start_application() {
    local PORT=$1
    local ENVIRONMENT=$2
    local LOG_FILE="$SCRIPT_DIR/logs/terracotta-$ENVIRONMENT.log"

    mkdir -p "$SCRIPT_DIR/logs"

    if is_port_in_use "$PORT"; then
        echo "$ENVIRONMENT server port $PORT is already in use."
        exit 1
    fi

    nohup "$JAVA_HOME/bin/java" \
        -Dcontrast.protect.enable=$PROTECT_ENABLE \
        -Dcontrast.assess.enable=$ASSESS_ENABLE \
        -Dcontrast.observe.enable=true \
        -Dcontrast.server.name=terracotta-"$ENVIRONMENT" \
        -Dcontrast.server.environment="$ENVIRONMENT" \
        -Dcontrast.config.path="$SCRIPT_DIR/contrast_security.yaml" \
        -Dcontrast.agent.polling.app_activity_ms=1000 \
        -javaagent:"$SCRIPT_DIR/contrast-agent.jar" \
        -Dserver.port="$PORT" \
        -jar "$SCRIPT_DIR/terracotta.war" >"$LOG_FILE" 2>&1 &

    wait_for_server "$PORT" "$ENVIRONMENT"
}

# Main script

# Determine the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Configuration options
PROTECT_ENABLE=false
ASSESS_ENABLE=false

# Check if the required commands are available
if ! command -v curl >/dev/null; then
    echo "Error: 'curl' command not found. Please install 'curl' to run this script."
    exit 1
fi

if ! command -v tar >/dev/null; then
    echo "Error: 'tar' command not found. Please install 'tar' to run this script."
    exit 1
fi

# Detect OS and Architecture
OS_ARCH=$(detect_os_arch)

# Determine the correct JAVA_HOME based on OS and architecture
if [[ "$OS_ARCH" == "mac/x64" || "$OS_ARCH" == "mac/aarch64" ]]; then
    JAVA_HOME="$SCRIPT_DIR/jre/$OS_ARCH/Contents/Home"
else
    JAVA_HOME="$SCRIPT_DIR/jre/$OS_ARCH"
fi

# Check Java version and download JRE if necessary
if (! check_installed_java_version); then
    echo "Checking and setting up the required JRE for $OS_ARCH..."
    if (check_jre_downloaded "$OS_ARCH"); then
        JAVA_HOME="$SCRIPT_DIR/jre/$OS_ARCH"
        export JAVA_HOME
    else
        echo "Downloading and setting up the required JRE for $OS_ARCH..."
        if ! download_jre "$(echo "$OS_ARCH" | cut -d'/' -f2)" "$(echo "$OS_ARCH" | cut -d'/' -f1)"; then
            echo "Error: Failed to download the required JRE for $OS_ARCH."
            exit 1
        fi
    fi
    if [[ "$OS_ARCH" == "mac/x64" || "$OS_ARCH" == "mac/aarch64" ]]; then
        JAVA_HOME="$SCRIPT_DIR/jre/$OS_ARCH/Contents/Home"
    else
        JAVA_HOME="$SCRIPT_DIR/jre/$OS_ARCH"
    fi
    export JAVA_HOME
    check_downloaded_jre_version "$OS_ARCH"
fi

# Check configuration file
check_config_file

# Start the application based on command-line arguments
if [[ -z "$1" ]]; then
    COMMAND="all"
else
    COMMAND="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
fi

case "$COMMAND" in
"assess")
    ASSESS_ENABLE=true
    start_application 8080 "DEVELOPMENT"
    ;;
"protect")
    PROTECT_ENABLE=true
    start_application 8082 "PRODUCTION"
    ;;
"all")
    ASSESS_ENABLE=true
    start_application 8080 "DEVELOPMENT"
    ASSESS_ENABLE=false
    PROTECT_ENABLE=true
    start_application 8082 "PRODUCTION"
    ;;
*)
    echo "Usage: $0 {assess|protect|all}"
    exit 1
    ;;
esac
