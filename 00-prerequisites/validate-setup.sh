#!/bin/bash
# Validate setup for HIPAA/FedRAMP implementation

# Load environment
source ../config/environment.conf
load_state

echo "===================================="
echo "Validating Setup"
echo "===================================="
echo ""

# Check if prerequisites were checked
if [ "$PREREQUISITES_CHECKED" != "true" ]; then
    print_error "Prerequisites not checked. Run ./check-requirements.sh first"
    exit 1
fi

# Validate critical environment variables
print_info "Validating environment configuration..."

VALIDATION_PASSED=true

# Organization validation
if gcloud organizations describe "$ORG_ID" &>/dev/null 2>&1; then
    check_status "Organization $ORG_ID is accessible"
else
    check_status "Organization $ORG_ID is accessible"
    VALIDATION_PASSED=false
fi

# Billing account validation
if gcloud billing accounts describe "$BILLING_ACCOUNT_ID" &>/dev/null 2>&1; then
    check_status "Billing account $BILLING_ACCOUNT_ID is valid"
else
    check_status "Billing account $BILLING_ACCOUNT_ID is valid"
    VALIDATION_PASSED=false
fi

# Validate required organization settings
print_info "Validating organization settings..."

if [ -z "$ORGANIZATION_DOMAIN" ]; then
    check_status "Organization domain configured"
    print_error "ORGANIZATION_DOMAIN not set in config"
    VALIDATION_PASSED=false
else
    check_status "Organization domain set: $ORGANIZATION_DOMAIN"
fi

if [ -z "$ORGANIZATION_SHORT" ]; then
    check_status "Organization short name configured"
    print_error "ORGANIZATION_SHORT not set in config"
    VALIDATION_PASSED=false
else
    check_status "Organization short name set: $ORGANIZATION_SHORT"
fi

if [ -z "$CORPORATE_IP_RANGES" ]; then
    check_status "Corporate IP ranges configured"
    print_error "CORPORATE_IP_RANGES not set - admin access will not be restricted"
    VALIDATION_PASSED=false
else
    check_status "Corporate IP ranges configured"
fi

# Network configuration validation (if using VPN)
print_info "Validating network configuration..."

# Check if CIDR ranges are valid (only if provided)
if [ -n "$ON_PREM_NETWORK_RANGE" ]; then
    if [[ "$ON_PREM_NETWORK_RANGE" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        check_status "On-premises network range is valid: $ON_PREM_NETWORK_RANGE"
    else
        check_status "On-premises network range format"
        print_error "Invalid CIDR format for ON_PREM_NETWORK_RANGE"
        VALIDATION_PASSED=false
    fi
else
    print_warning "No on-premises network range configured (VPN will not be set up)"
fi

# Validate VPN peer IP (only if provided)
if [ -n "$PEER_IP" ]; then
    if [[ "$PEER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        check_status "VPN peer IP is valid: $PEER_IP"
    else
        check_status "VPN peer IP format"
        print_error "Invalid IP format for PEER_IP"
        VALIDATION_PASSED=false
    fi
else
    print_info "No VPN peer IP configured (hybrid connectivity not enabled)"
fi

# Check project naming
print_info "Validating project naming..."

# Check if project IDs are valid (6-30 characters, lowercase letters, numbers, and hyphens)
for PROJECT in "$PROJECT_ID" "$LOG_PROJECT_ID" "$RESEARCH_PROJECT_ID"; do
    if [[ "$PROJECT" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
        check_status "Project ID valid: $PROJECT"
    else
        check_status "Project ID format: $PROJECT"
        print_error "Invalid project ID format. Must be 6-30 chars, lowercase letters, numbers, and hyphens"
        VALIDATION_PASSED=false
    fi
done

# Check if projects already exist
print_info "Checking for existing projects..."

for PROJECT in "$PROJECT_ID" "$LOG_PROJECT_ID" "$RESEARCH_PROJECT_ID"; do
    if gcloud projects describe "$PROJECT" &>/dev/null 2>&1; then
        print_warning "Project already exists: $PROJECT"
        print_warning "You may need to use different project IDs or delete existing projects"
    fi
done

# Validate region
print_info "Validating regional configuration..."

FEDRAMP_REGIONS=("us-central1" "us-east1" "us-east4" "us-west1" "us-west2" "us-west3" "us-west4")
if [[ " ${FEDRAMP_REGIONS[@]} " =~ " ${REGION} " ]]; then
    check_status "Region $REGION is FedRAMP approved"
else
    check_status "Region validation"
    print_error "Region $REGION is not FedRAMP approved"
    print_error "Use one of: ${FEDRAMP_REGIONS[*]}"
    VALIDATION_PASSED=false
fi

# Check API enablement permissions
print_info "Checking API enablement permissions..."

if gcloud services list --available --limit=1 &>/dev/null 2>&1; then
    check_status "Can list available APIs"
else
    check_status "API listing permissions"
    print_warning "May not have permissions to enable APIs"
fi

echo ""

# Final validation summary
if [ "$VALIDATION_PASSED" = true ]; then
    print_success "All validations passed!"
    echo ""
    echo "Environment is ready for implementation."
    echo "You can now proceed to Phase 01: Foundation"
    echo ""
    echo "Run: cd ../01-foundation && ./create-folder.sh"
    
    # Update state
    echo "export SETUP_VALIDATED=true" >> ../config/state.conf
    echo "export VALIDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ../config/state.conf
else
    print_error "Validation failed. Please fix the issues above."
    exit 1
fi
