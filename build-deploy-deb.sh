#!/bin/bash

# Configuration
REMOTE_HOST="10.1.1.8"
REMOTE_USER="root"
PACKAGE_NAME="pertisk-eproxy"
PACKAGE_VERSION="0.2.33"
DEB_FILE="${PACKAGE_NAME}_${PACKAGE_VERSION}_amd64.deb"
REMOTE_PATH="/tmp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting deployment of ${PACKAGE_NAME} version ${PACKAGE_VERSION}${NC}"

# Step 1: Build the package
echo -e "${YELLOW}Building Debian package...${NC}"
make package-deb-amd64 PACKAGE_VERSION=${PACKAGE_VERSION}

if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed! Exiting...${NC}"
    exit 1
fi

# Step 2: Copy package to remote server
echo -e "${YELLOW}Copying package to remote server...${NC}"
scp release/${DEB_FILE} ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/

if [ $? -ne 0 ]; then
    echo -e "${RED}SCP failed! Exiting...${NC}"
    exit 1
fi

# Step 3: Install/Update on remote server
echo -e "${YELLOW}Installing/updating on remote server...${NC}"
ssh ${REMOTE_USER}@${REMOTE_HOST} << EOF
    # Install/update the package
    sudo apt install ${REMOTE_PATH}/${DEB_FILE} -y
    
    if [ $? -eq 0 ]; then
        echo "Package installed/updated successfully"
        
        # Enable and restart service
        sudo systemctl enable ${PACKAGE_NAME} --now
        sudo systemctl restart ${PACKAGE_NAME}
        
        # Check service status
        echo "Service status:"
        sudo systemctl status ${PACKAGE_NAME} --no-pager
    else
        echo "Package installation failed!"
        exit 1
    fi
EOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Deployment completed successfully!${NC}"
else
    echo -e "${RED}Deployment failed!${NC}"
    exit 1
fi