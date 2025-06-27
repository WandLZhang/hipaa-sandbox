#!/bin/bash
# Set up environment for HIPAA/FedRAMP implementation

echo "===================================="
echo "Setting up environment"
echo "===================================="
echo ""

# Check if environment.conf exists
if [ ! -f ../config/environment.conf ]; then
    echo "ERROR: ../config/environment.conf not found!"
    echo "Please ensure you're running this from the 00-prerequisites directory."
    exit 1
fi

# Source the environment
source ../config/environment.conf

# Display current configuration
echo "Current Configuration:"
echo "===================="
echo "Organization ID: $ORG_ID"
echo "Organization Domain: $ORGANIZATION_DOMAIN"
echo "Organization Short Name: $ORGANIZATION_SHORT"
echo "Billing Account: $BILLING_ACCOUNT_ID"
echo "Region: $REGION"
echo "Primary Project: $PROJECT_ID"
echo "Research Project: $RESEARCH_PROJECT_ID"
echo "Corporate IP Ranges: $CORPORATE_IP_RANGES"
echo ""

# Check for required variables
MISSING_VARS=false

if [ -z "$ORG_ID" ]; then
    print_error "ORG_ID not configured"
    MISSING_VARS=true
fi

if [ -z "$BILLING_ACCOUNT_ID" ]; then
    print_error "BILLING_ACCOUNT_ID not configured"
    MISSING_VARS=true
fi

if [ -z "$ORGANIZATION_DOMAIN" ]; then
    print_error "ORGANIZATION_DOMAIN not configured"
    MISSING_VARS=true
fi

if [ -z "$ORGANIZATION_SHORT" ]; then
    print_error "ORGANIZATION_SHORT not configured"
    MISSING_VARS=true
fi

if [ -z "$CORPORATE_IP_RANGES" ]; then
    print_error "CORPORATE_IP_RANGES not configured"
    MISSING_VARS=true
fi

# Check optional VPN settings only if VPN is being used
if [ -n "$ON_PREM_NETWORK_RANGE" ]; then
    if [ -z "$PEER_IP" ]; then
        print_error "PEER_IP not configured (required when ON_PREM_NETWORK_RANGE is set)"
        MISSING_VARS=true
    fi
    
    if [ -z "$SHARED_SECRET" ]; then
        print_error "SHARED_SECRET not configured (required when ON_PREM_NETWORK_RANGE is set)"
        MISSING_VARS=true
    fi
    
    if [ -z "$PEER_ASN" ]; then
        print_error "PEER_ASN not configured (required when ON_PREM_NETWORK_RANGE is set)"
        MISSING_VARS=true
    fi
fi

if [ "$MISSING_VARS" = true ]; then
    echo ""
    print_error "Please edit ../config/environment.conf and update the required values"
    exit 1
fi

# Set some default configurations
echo ""
print_info "Setting default gcloud configurations..."

# Set default project (will be changed later)
gcloud config set project ${PROJECT_ID} 2>/dev/null || true

# Set default region
gcloud config set compute/region ${REGION}

# Set default zone
gcloud config set compute/zone ${ZONE}

# Enable required APIs at organization level
print_info "Enabling organization-level APIs..."
gcloud services enable cloudresourcemanager.googleapis.com \
    accesscontextmanager.googleapis.com \
    assuredworkloads.googleapis.com \
    securitycenter.googleapis.com \
    2>/dev/null || print_warning "Some APIs may require organization admin permissions"

echo ""
print_success "Environment configuration loaded successfully!"
echo ""
echo "Next steps:"
echo "1. Run ./validate-setup.sh to validate the configuration"
echo "2. Proceed to Phase 01 once validation passes"
