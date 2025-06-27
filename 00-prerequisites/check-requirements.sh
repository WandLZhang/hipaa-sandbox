#!/bin/bash
# Check prerequisites for HIPAA/FedRAMP implementation

# Load helper functions
source ../config/environment.conf

echo "===================================="
echo "HIPAA/FedRAMP Prerequisites Check"
echo "===================================="
echo ""

# Track overall status
PREREQ_MET=true

# Check required tools
print_info "Checking required tools..."

# Check gcloud
if command -v gcloud &> /dev/null; then
    GCLOUD_VERSION=$(gcloud version --format="value(Google Cloud SDK)")
    check_status "gcloud CLI installed (version: $GCLOUD_VERSION)"
else
    check_status "gcloud CLI installed"
    PREREQ_MET=false
    print_error "Please install gcloud SDK: https://cloud.google.com/sdk/docs/install"
fi

# Check gsutil
if command -v gsutil &> /dev/null; then
    check_status "gsutil installed"
else
    check_status "gsutil installed"
    PREREQ_MET=false
fi

# Check bq
if command -v bq &> /dev/null; then
    check_status "bq (BigQuery CLI) installed"
else
    check_status "bq (BigQuery CLI) installed"
    PREREQ_MET=false
fi

# Check curl
if command -v curl &> /dev/null; then
    check_status "curl installed"
else
    check_status "curl installed"
    PREREQ_MET=false
fi

# Check jq
if command -v jq &> /dev/null; then
    check_status "jq installed"
else
    check_status "jq installed"
    PREREQ_MET=false
    print_warning "jq is recommended for JSON parsing"
fi

echo ""

# Check authentication
print_info "Checking Google Cloud authentication..."

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -n "$ACTIVE_ACCOUNT" ]; then
    check_status "Authenticated as: $ACTIVE_ACCOUNT"
else
    check_status "Google Cloud authentication"
    PREREQ_MET=false
    print_error "Please run: gcloud auth login"
fi

# Check application default credentials
if gcloud auth application-default print-access-token &>/dev/null 2>&1; then
    check_status "Application default credentials configured"
else
    check_status "Application default credentials"
    print_warning "Run: gcloud auth application-default login"
fi

echo ""

# Check organization access
print_info "Checking organization access..."

if [ -z "$ORG_ID" ]; then
    print_error "ORG_ID not configured in ../config/environment.conf"
    PREREQ_MET=false
else
    # Try to describe the organization
    if gcloud organizations describe "$ORG_ID" &>/dev/null 2>&1; then
        check_status "Access to organization: $ORG_ID"
        
        # Check specific permissions
        print_info "Checking required permissions..."
        
        # Check organization admin
        if gcloud organizations get-iam-policy "$ORG_ID" \
            --flatten="bindings[].members" \
            --format="table(bindings.role)" \
            --filter="bindings.members:$ACTIVE_ACCOUNT AND bindings.role:roles/resourcemanager.organizationAdmin" &>/dev/null 2>&1; then
            check_status "Organization Admin role"
        else
            check_status "Organization Admin role"
            print_warning "You may need Organization Admin role for some operations"
        fi
        
    else
        check_status "Access to organization: $ORG_ID"
        PREREQ_MET=false
        print_error "Cannot access organization. Check permissions."
    fi
fi

echo ""

# Check billing account
print_info "Checking billing account..."

if [ -z "$BILLING_ACCOUNT_ID" ]; then
    print_error "BILLING_ACCOUNT_ID not configured in ../config/environment.conf"
    PREREQ_MET=false
else
    # Try to describe the billing account
    if gcloud billing accounts describe "$BILLING_ACCOUNT_ID" &>/dev/null 2>&1; then
        check_status "Access to billing account: $BILLING_ACCOUNT_ID"
    else
        check_status "Access to billing account"
        print_warning "Cannot verify billing account access"
    fi
fi

echo ""

# Summary
if [ "$PREREQ_MET" = true ]; then
    print_success "All prerequisites met! You can proceed to Phase 01."
else
    print_error "Some prerequisites are missing. Please address the issues above."
    exit 1
fi

# Save state
mkdir -p ../config
echo "# Prerequisites validated on $(date)" > ../config/state.conf
echo "export PREREQUISITES_CHECKED=true" >> ../config/state.conf
echo "export CHECKED_BY=$ACTIVE_ACCOUNT" >> ../config/state.conf

print_info "State saved to ../config/state.conf"
