#!/bin/bash
# Set up HA-VPN for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting up HA-VPN"
echo "===================================="
echo ""

# Check prerequisites
if [ "$FIREWALL_CONFIGURED" != "true" ]; then
    print_error "Firewall not configured. Run ./configure-firewall.sh first."
    exit 1
fi

# Set project context
gcloud config set project "$PROJECT_ID"

# Check if VPN configuration is provided
if [ -z "$ON_PREM_NETWORK_RANGE" ] || [ -z "$PEER_IP" ] || [ -z "$SHARED_SECRET" ] || [ -z "$PEER_ASN" ]; then
    print_warning "VPN configuration not provided. Skipping VPN setup."
    print_info "VPN is optional - only needed for hybrid connectivity."
    save_state "VPN_CONFIGURED" "skipped"
    echo ""
    echo "Next step: ./configure-dns.sh"
    exit 0
fi

# Create Cloud Router
print_info "Creating Cloud Router: $CLOUD_ROUTER_NAME"

if gcloud compute routers describe "$CLOUD_ROUTER_NAME" --region="$REGION" &>/dev/null 2>&1; then
    print_warning "Cloud Router already exists: $CLOUD_ROUTER_NAME"
else
    if gcloud compute routers create "$CLOUD_ROUTER_NAME" \
        --network="$VPC_NAME" \
        --asn="$CLOUD_ROUTER_ASN" \
        --region="$REGION" \
        --project="$PROJECT_ID"; then
        print_success "Cloud Router created"
    else
        print_error "Failed to create Cloud Router"
        exit 1
    fi
fi

# Create VPN gateway
print_info "Creating HA-VPN gateway: $VPN_GATEWAY_NAME"

if gcloud compute vpn-gateways describe "$VPN_GATEWAY_NAME" --region="$REGION" &>/dev/null 2>&1; then
    print_warning "VPN gateway already exists: $VPN_GATEWAY_NAME"
else
    if gcloud compute vpn-gateways create "$VPN_GATEWAY_NAME" \
        --network="$VPC_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID"; then
        print_success "VPN gateway created"
    else
        print_error "Failed to create VPN gateway"
        exit 1
    fi
fi

# Get VPN gateway IPs
print_info "Getting VPN gateway interface IPs..."

VPN_GW_IP_0=$(gcloud compute vpn-gateways describe "$VPN_GATEWAY_NAME" \
    --region="$REGION" \
    --format='get(vpnInterfaces[0].interconnectAttachment)' \
    --project="$PROJECT_ID")

VPN_GW_IP_1=$(gcloud compute vpn-gateways describe "$VPN_GATEWAY_NAME" \
    --region="$REGION" \
    --format='get(vpnInterfaces[1].interconnectAttachment)' \
    --project="$PROJECT_ID")

# Display gateway IPs for on-premises configuration
print_info "VPN Gateway External IPs (provide these to your network team):"
echo "Interface 0: $(gcloud compute vpn-gateways describe "$VPN_GATEWAY_NAME" \
    --region="$REGION" \
    --format='get(vpnInterfaces[0].id)'): IP not yet assigned"
echo "Interface 1: $(gcloud compute vpn-gateways describe "$VPN_GATEWAY_NAME" \
    --region="$REGION" \
    --format='get(vpnInterfaces[1].id)'): IP not yet assigned"

# Create VPN tunnels
print_info "Creating VPN tunnel: ${VPN_TUNNEL_NAME}-1"

if gcloud compute vpn-tunnels describe "${VPN_TUNNEL_NAME}-1" --region="$REGION" &>/dev/null 2>&1; then
    print_warning "VPN tunnel already exists: ${VPN_TUNNEL_NAME}-1"
else
    if gcloud compute vpn-tunnels create "${VPN_TUNNEL_NAME}-1" \
        --peer-address="$PEER_IP" \
        --vpn-gateway="$VPN_GATEWAY_NAME" \
        --ike-version=2 \
        --shared-secret="$SHARED_SECRET" \
        --router="$CLOUD_ROUTER_NAME" \
        --interface=0 \
        --region="$REGION" \
        --project="$PROJECT_ID"; then
        print_success "VPN tunnel created"
    else
        print_error "Failed to create VPN tunnel"
        exit 1
    fi
fi

# Configure Cloud Router interface
print_info "Configuring Cloud Router interface..."

if gcloud compute routers describe "$CLOUD_ROUTER_NAME" --region="$REGION" \
    --format="value(interfaces[0].name)" | grep -q "if-tunnel-1"; then
    print_warning "Router interface already exists: if-tunnel-1"
else
    if gcloud compute routers add-interface "$CLOUD_ROUTER_NAME" \
        --interface-name=if-tunnel-1 \
        --ip-address=169.254.0.1 \
        --mask-length=30 \
        --vpn-tunnel="${VPN_TUNNEL_NAME}-1" \
        --region="$REGION" \
        --project="$PROJECT_ID"; then
        print_success "Router interface configured"
    else
        print_error "Failed to configure router interface"
        exit 1
    fi
fi

# Add BGP peer
print_info "Adding BGP peer..."

if gcloud compute routers describe "$CLOUD_ROUTER_NAME" --region="$REGION" \
    --format="value(bgpPeers[0].name)" | grep -q "bgp-peer-1"; then
    print_warning "BGP peer already exists: bgp-peer-1"
else
    if gcloud compute routers add-bgp-peer "$CLOUD_ROUTER_NAME" \
        --peer-name=bgp-peer-1 \
        --interface=if-tunnel-1 \
        --peer-ip-address=169.254.0.2 \
        --peer-asn="$PEER_ASN" \
        --region="$REGION" \
        --project="$PROJECT_ID"; then
        print_success "BGP peer added"
    else
        print_error "Failed to add BGP peer"
        exit 1
    fi
fi

# Update BGP peer to advertise restricted.googleapis.com range
print_info "Configuring BGP advertisement for restricted APIs..."

if gcloud compute routers update-bgp-peer "$CLOUD_ROUTER_NAME" \
    --peer-name=bgp-peer-1 \
    --advertisement-mode=CUSTOM \
    --set-advertisement-groups=ALL_SUBNETS \
    --set-advertisement-ranges=199.36.153.4/30 \
    --region="$REGION" \
    --project="$PROJECT_ID"; then
    print_success "BGP advertisement configured"
else
    print_warning "Failed to configure BGP advertisement"
fi

# Check VPN tunnel status
print_info "Checking VPN tunnel status..."

TUNNEL_STATUS=$(gcloud compute vpn-tunnels describe "${VPN_TUNNEL_NAME}-1" \
    --region="$REGION" \
    --format="value(detailedStatus)" \
    --project="$PROJECT_ID")

echo "Tunnel Status: $TUNNEL_STATUS"

if [[ "$TUNNEL_STATUS" == *"Tunnel is up and running"* ]]; then
    check_status "VPN tunnel is UP"
else
    print_warning "VPN tunnel is not yet established"
    print_warning "Status: $TUNNEL_STATUS"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Verify peer IP address: $PEER_IP"
    echo "2. Verify shared secret matches on both sides"
    echo "3. Check firewall rules on peer device"
    echo "4. Ensure IKEv2 is configured on peer"
fi

# Update state
save_state "VPN_CONFIGURED" "true"
save_state "VPN_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "HA-VPN configuration completed!"
echo ""
echo "VPN Details:"
echo "- Gateway: $VPN_GATEWAY_NAME"
echo "- Tunnel: ${VPN_TUNNEL_NAME}-1"
echo "- Cloud Router: $CLOUD_ROUTER_NAME (ASN: $CLOUD_ROUTER_ASN)"
echo "- Peer IP: $PEER_IP (ASN: $PEER_ASN)"
echo "- BGP advertises: 199.36.153.4/30 (restricted.googleapis.com)"
echo ""
echo "Next step: ./configure-dns.sh"
