#!/bin/bash
# Configure firewall rules for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Configuring Firewall Rules"
echo "===================================="
echo ""

# Check prerequisites
if [ "$VPC_CREATED" != "true" ]; then
    print_error "VPC not created. Run ./create-vpc.sh first."
    exit 1
fi

# Set project context
gcloud config set project "$PROJECT_ID"

# Function to create firewall rule
create_firewall_rule() {
    local RULE_NAME=$1
    local DESCRIPTION=$2
    local DIRECTION=$3
    local ACTION=$4
    local RULES=$5
    local SOURCE_RANGES=$6
    local PRIORITY=$7
    local TARGET_TAGS=$8
    
    print_info "Creating firewall rule: $RULE_NAME"
    
    # Check if rule already exists
    if gcloud compute firewall-rules describe "$RULE_NAME" &>/dev/null 2>&1; then
        print_warning "Firewall rule already exists: $RULE_NAME"
        return 0
    fi
    
    # Build command
    local CMD="gcloud compute firewall-rules create $RULE_NAME"
    CMD="$CMD --description=\"$DESCRIPTION\""
    CMD="$CMD --direction=$DIRECTION"
    CMD="$CMD --priority=$PRIORITY"
    CMD="$CMD --network=$VPC_NAME"
    CMD="$CMD --action=$ACTION"
    
    if [ -n "$RULES" ]; then
        CMD="$CMD --rules=$RULES"
    fi
    
    if [ -n "$SOURCE_RANGES" ]; then
        CMD="$CMD --source-ranges=$SOURCE_RANGES"
    fi
    
    if [ -n "$TARGET_TAGS" ]; then
        CMD="$CMD --target-tags=$TARGET_TAGS"
    fi
    
    CMD="$CMD --project=$PROJECT_ID"
    
    # Execute command
    if eval $CMD; then
        check_status "Created: $RULE_NAME"
        return 0
    else
        check_status "Failed to create: $RULE_NAME"
        return 1
    fi
}

# Create deny-all ingress rule (highest priority)
create_firewall_rule \
    "deny-all-ingress" \
    "Deny all ingress traffic by default" \
    "INGRESS" \
    "DENY" \
    "all" \
    "0.0.0.0/0" \
    "65534" \
    ""

# Allow internal communication
create_firewall_rule \
    "allow-internal" \
    "Allow internal subnet communication" \
    "INGRESS" \
    "ALLOW" \
    "all" \
    "$SUBNET_RANGE" \
    "1000" \
    ""

# Allow SSH from corporate networks only
create_firewall_rule \
    "allow-ssh-from-corp" \
    "Allow SSH from corporate networks" \
    "INGRESS" \
    "ALLOW" \
    "tcp:22" \
    "$CORPORATE_IP_RANGES" \
    "1000" \
    "allow-ssh"

# Allow SSH from on-premises network (via VPN)
create_firewall_rule \
    "allow-ssh-from-onprem" \
    "Allow SSH from on-premises network" \
    "INGRESS" \
    "ALLOW" \
    "tcp:22" \
    "$ON_PREM_NETWORK_RANGE" \
    "1000" \
    "allow-ssh"

# Allow health checks from Google
create_firewall_rule \
    "allow-health-checks" \
    "Allow Google Cloud health checks" \
    "INGRESS" \
    "ALLOW" \
    "tcp" \
    "35.191.0.0/16,130.211.0.0/22" \
    "1000" \
    "allow-health-check"

# Allow established connections (stateful firewall behavior)
create_firewall_rule \
    "allow-established" \
    "Allow established connections" \
    "INGRESS" \
    "ALLOW" \
    "tcp:1-65535,udp:1-65535,icmp" \
    "0.0.0.0/0" \
    "1100" \
    "allow-established"

# Deny all egress except to specific destinations
create_firewall_rule \
    "deny-all-egress" \
    "Deny all egress by default" \
    "EGRESS" \
    "DENY" \
    "all" \
    "0.0.0.0/0" \
    "65534" \
    ""

# Allow egress to Google APIs
create_firewall_rule \
    "allow-google-apis-egress" \
    "Allow egress to Google APIs" \
    "EGRESS" \
    "ALLOW" \
    "tcp:443" \
    "199.36.153.4/30,*.googleapis.com,*.google.com" \
    "1000" \
    ""

# Allow egress to internal subnet
create_firewall_rule \
    "allow-internal-egress" \
    "Allow egress within subnet" \
    "EGRESS" \
    "ALLOW" \
    "all" \
    "$SUBNET_RANGE" \
    "1000" \
    ""

# Allow DNS egress
create_firewall_rule \
    "allow-dns-egress" \
    "Allow DNS queries" \
    "EGRESS" \
    "ALLOW" \
    "tcp:53,udp:53" \
    "0.0.0.0/0" \
    "1000" \
    ""

echo ""

# Display firewall rules
print_info "Current firewall rules for VPC $VPC_NAME:"
gcloud compute firewall-rules list \
    --filter="network:$VPC_NAME" \
    --format="table(name,direction,priority,sourceRanges[].list():label=SRC_RANGES,allowed[].map().firewall_rule().list():label=ALLOW,targetTags.list():label=TARGET_TAGS)" \
    --project="$PROJECT_ID"

# Update state
save_state "FIREWALL_CONFIGURED" "true"
save_state "FIREWALL_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Firewall rules configured successfully!"
echo ""
echo "Security posture:"
echo "- Default deny all ingress (priority 65534)"
echo "- Default deny all egress (priority 65534)"
echo "- Allow internal communication only"
echo "- SSH access restricted to corporate networks"
echo "- Egress allowed only to Google APIs and DNS"
echo ""
echo "Next step: ./setup-vpn.sh"
