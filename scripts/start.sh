#!/bin/bash

# Function to check if a port is in use
is_port_in_use() {
    netstat -an | grep "$1" | grep LISTEN > /dev/null
    return $?
}

# Function to check if the application is ready
wait_for_server() {
    PORT=$1
    echo "Waiting for server on port $PORT to be ready..."
    while ! curl --output /dev/null --silent --head --fail http://localhost:"$PORT"; do
        printf '.'
        sleep 2
    done
    echo "Server on port $PORT is ready!"
}

# Check if the contrast_security.yaml file exists
CONFIG_FILE="contrast_security.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file '$CONFIG_FILE' not found. Please ensure it is present in the same directory as this script."
    exit 1
fi

# Start the application in DEVELOPMENT mode (Assess)
DEV_PORT=8080
DEV_LOG="terracotta-dev.log"
if is_port_in_use $DEV_PORT; then
    echo "Development server port $DEV_PORT is already in use."
    exit 1
else
    nohup java -Dcontrast.protect.enable=false -Dcontrast.assess.enable=true \
    -Dcontrast.server.environment=DEVELOPMENT -Dserver.port=$DEV_PORT \
    -Dcontrast.config.path=$CONFIG_FILE \
    -javaagent:contrast-agent.jar -jar terracotta.war > $DEV_LOG 2>&1 &
    wait_for_server $DEV_PORT
fi

# Start the application in PRODUCTION mode (Protect)
PROD_PORT=8082
PROD_LOG="terracotta-prod.log"
if is_port_in_use $PROD_PORT; then
    echo "Production server port $PROD_PORT is already in use."
    exit 1
else
    nohup java -Dcontrast.protect.enable=true -Dcontrast.assess.enable=false \
    -Dcontrast.server.environment=PRODUCTION -Dserver.port=$PROD_PORT \
    -Dcontrast.config.path=$CONFIG_FILE \
    -javaagent:contrast-agent.jar -jar terracotta.war > $PROD_LOG 2>&1 &
    wait_for_server $PROD_PORT
fi
