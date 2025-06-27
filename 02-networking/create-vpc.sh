#!/bin/bash
# Create dedicated VPC for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Creating Dedicated VPC Network"
echo "===================================="
echo ""

# Check prerequisites
if [ "$PHASE_01_COMPLETE" != "true" ]; then
    print_error "Phase 01 not complete. Please complete foundation setup first."
    exit 1
fi

# Set project context
gcloud config set project "$PROJECT_ID"

# Check if VPC already exists
print_info "Checking for existing VPC..."

if gcloud compute networks describe "$VPC_NAME" &>/dev/null 2>&1; then
    print_warning "VPC already exists: $VPC_NAME"
    print_info "Skipping VPC creation"
else
    # Create VPC
    print_info "Creating dedicated VPC: $VPC_NAME"
    
    if gcloud compute networks create "$VPC_NAME" \
        --subnet-mode=custom \
        --bgp-routing-mode=regional \
        --project="$PROJECT_ID"; then
        print_success "VPC created: $VPC_NAME"
    else
        print_error "Failed to create VPC"
        exit 1
    fi
fi

# Check if subnet already exists
print_info "Checking for existing subnet..."

if gcloud compute networks subnets describe "$SUBNET_NAME" \
    --region="$REGION" &>/dev/null 2>&1; then
    print_warning "Subnet already exists: $SUBNET_NAME"
    print_info "Skipping subnet creation"
else
    # Create subnet
    print_info "Creating subnet: $SUBNET_NAME"
    
    if gcloud compute networks subnets create "$SUBNET_NAME" \
        --network="$VPC_NAME" \
        --range="$SUBNET_RANGE" \
        --region="$REGION" \
        --enable-private-ip-google-access \
        --enable-flow-logs \
        --logging-flow-sampling=1.0 \
        --project="$PROJECT_ID"; then
        print_success "Subnet created: $SUBNET_NAME ($SUBNET_RANGE)"
    else
        print_error "Failed to create subnet"
        exit 1
    fi
fi

# Create route for restricted Google APIs
print_info "Creating route for restricted.googleapis.com..."

ROUTE_NAME="restricted-google-apis"
if gcloud compute routes describe "$ROUTE_NAME" &>/dev/null 2>&1; then
    print_warning "Route already exists: $ROUTE_NAME"
else
    if gcloud compute routes create "$ROUTE_NAME" \
        --network="$VPC_NAME" \
        --destination-range="199.36.153.4/30" \
        --next-hop-gateway="default-internet-gateway" \
        --priority=100 \
        --project="$PROJECT_ID"; then
        print_success "Created route for restricted APIs"
    else
        print_warning "Failed to create route for restricted APIs"
    fi
fi

# Display VPC configuration
print_info "VPC Configuration:"
echo "=================="
gcloud compute networks describe "$VPC_NAME" \
    --format="yaml(name,autoCreateSubnetworks,routingConfig)"

echo ""
print_info "Subnet Configuration:"
echo "===================="
gcloud compute networks subnets describe "$SUBNET_NAME" \
    --region="$REGION" \
    --format="yaml(name,ipCidrRange,privateIpGoogleAccess,enableFlowLogs)"

# Update state
save_state "VPC_CREATED" "true"
save_state "VPC_CREATED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Dedicated VPC created successfully!"
echo ""
echo "VPC Details:"
echo "- Name: $VPC_NAME"
echo "- Mode: Custom subnets (not auto-mode)"
echo "- Routing: Regional"
echo "- Subnet: $SUBNET_NAME ($SUBNET_RANGE)"
echo "- Private Google Access: Enabled"
echo "- Flow Logs: Enabled (100% sampling)"
echo ""
echo "Next step: ./configure-firewall.sh"
