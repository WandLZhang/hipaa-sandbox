#!/bin/bash
# Make all implementation scripts executable

echo "Making all scripts executable..."

# Make this script executable first
chmod +x make-executable.sh

# Make all phase scripts executable
find . -name "*.sh" -type f -exec chmod +x {} \;

echo "All scripts are now executable!"
echo ""
echo "To start the implementation:"
echo "1. First, edit config/environment.conf with your values"
echo "2. Then run: cd 00-prerequisites && ./check-requirements.sh"
