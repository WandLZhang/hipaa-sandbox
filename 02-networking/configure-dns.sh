#!/bin/bash
# Configure DNS for restricted Google APIs

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Configuring DNS for Restricted APIs"
echo "===================================="
echo ""

# Check prerequisites
if [ "$VPN_CONFIGURED" != "true" ] && [ "$VPN_CONFIGURED" != "skipped" ]; then
    print_error "VPN setup not complete. Run ./setup-vpn.sh first."
    exit 1
fi

# Set project context
gcloud config set project "$PROJECT_ID"

# Create private DNS zone
print_info "Creating private DNS zone for googleapis.com..."

DNS_ZONE_NAME="googleapis"
if gcloud dns managed-zones describe "$DNS_ZONE_NAME" &>/dev/null 2>&1; then
    print_warning "DNS zone already exists: $DNS_ZONE_NAME"
else
    if gcloud dns managed-zones create "$DNS_ZONE_NAME" \
        --description="Private zone for Google APIs" \
        --dns-name="googleapis.com" \
        --networks="$VPC_NAME" \
        --visibility=private \
        --project="$PROJECT_ID"; then
        print_success "Private DNS zone created"
    else
        print_error "Failed to create DNS zone"
        exit 1
    fi
fi

# Function to create DNS record
create_dns_record() {
    local RECORD_NAME=$1
    local RECORD_TYPE=$2
    local TTL=$3
    local RRDATAS=$4
    
    print_info "Creating DNS record: $RECORD_NAME"
    
    # Check if record exists
    if gcloud dns record-sets describe "$RECORD_NAME" \
        --zone="$DNS_ZONE_NAME" \
        --type="$RECORD_TYPE" &>/dev/null 2>&1; then
        print_warning "DNS record already exists: $RECORD_NAME"
        return 0
    fi
    
    # Create record
    if gcloud dns record-sets create "$RECORD_NAME" \
        --zone="$DNS_ZONE_NAME" \
        --type="$RECORD_TYPE" \
        --ttl="$TTL" \
        --rrdatas="$RRDATAS" \
        --project="$PROJECT_ID"; then
        check_status "Created DNS record: $RECORD_NAME"
        return 0
    else
        check_status "Failed to create DNS record: $RECORD_NAME"
        return 1
    fi
}

# Add A records for restricted.googleapis.com
create_dns_record \
    "restricted.googleapis.com." \
    "A" \
    "300" \
    "199.36.153.4,199.36.153.5,199.36.153.6,199.36.153.7"

# Add CNAME record for wildcard
create_dns_record \
    "*.googleapis.com." \
    "CNAME" \
    "300" \
    "restricted.googleapis.com."

# Display DNS records
print_info "DNS records in zone $DNS_ZONE_NAME:"
gcloud dns record-sets list \
    --zone="$DNS_ZONE_NAME" \
    --project="$PROJECT_ID" \
    --format="table(name,type,ttl,rrdatas[].list():label=DATA)"

echo ""

# Test DNS resolution (if possible)
print_info "DNS Configuration Summary:"
echo "=========================="
echo "Private DNS zone created for: googleapis.com"
echo "All *.googleapis.com queries will resolve to restricted IPs:"
echo "- 199.36.153.4"
echo "- 199.36.153.5"
echo "- 199.36.153.6"
echo "- 199.36.153.7"
echo ""

print_warning "MANUAL STEP REQUIRED: On-Premises DNS Configuration"
print_warning "===================================================="
echo ""
echo "Configure your on-premises DNS servers to forward googleapis.com queries:"
echo ""
echo "1. Create a forward zone for: googleapis.com"
echo "2. Configure forwarders to Google Cloud DNS"
echo "3. OR configure static entries for:"
echo "   - restricted.googleapis.com -> 199.36.153.4-7"
echo "   - *.googleapis.com -> CNAME to restricted.googleapis.com"
echo ""
echo "Test from on-premises:"
echo "  nslookup storage.googleapis.com"
echo "  Should return one of: 199.36.153.4-7"
echo ""

# Update state
save_state "DNS_CONFIGURED" "true"
save_state "DNS_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
save_state "PHASE_02_COMPLETE" "true"

echo ""
print_success "Phase 02: Networking completed successfully!"
echo ""
echo "Summary:"
echo "- Dedicated VPC: $VPC_NAME"
echo "- Subnet: $SUBNET_NAME ($SUBNET_RANGE)"
echo "- Firewall: Default deny with specific allows"
echo "- VPN: $VPN_GATEWAY_NAME connected to $PEER_IP"
echo "- DNS: Private zone for googleapis.com -> restricted IPs"
echo ""
echo "Next phase: cd ../03-security-controls && ./setup-access-context.sh"
