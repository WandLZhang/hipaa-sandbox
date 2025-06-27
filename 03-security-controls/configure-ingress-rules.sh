#!/bin/bash
# Configure ingress rules for VPC Service Controls perimeters

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Configuring VPC-SC Ingress Rules"
echo "===================================="
echo ""

# Check prerequisites
if [ "$PERIMETERS_CREATED" != "true" ]; then
    print_error "Perimeters not created. Run ./create-perimeters.sh first."
    exit 1
fi

# Create ingress policy files
print_info "Creating ingress policy configurations..."

# Admin access ingress rule
cat > /tmp/ingress_admin.yaml <<EOF
ingressPolicies:
- ingressFrom:
    sources:
    - accessLevel: accessPolicies/${ACCESS_POLICY_NAME}/accessLevels/corp_network
EOF

# Add on-premises network access level if VPN is configured
if [ -n "$ON_PREM_NETWORK_RANGE" ]; then
    cat >> /tmp/ingress_admin.yaml <<EOF
    - accessLevel: accessPolicies/${ACCESS_POLICY_NAME}/accessLevels/on_prem_network
EOF
fi

cat >> /tmp/ingress_admin.yaml <<EOF
    identityType: ANY_IDENTITY
  ingressTo:
    operations:
    - serviceName: "*"
      methodSelectors:
      - method: "*"
    resources:
    - "*"
EOF

# On-premises application access rule (only if VPN is configured)
if [ -n "$ON_PREM_NETWORK_RANGE" ]; then
    cat > /tmp/ingress_onprem_apps.yaml <<EOF
ingressPolicies:
- ingressFrom:
    sources:
    - accessLevel: accessPolicies/${ACCESS_POLICY_NAME}/accessLevels/on_prem_network
    identityType: ANY_SERVICE_ACCOUNT
  ingressTo:
    operations:
    - serviceName: storage.googleapis.com
      methodSelectors:
      - method: "google.storage.objects.create"
      - method: "google.storage.objects.get"
      - method: "google.storage.objects.list"
    - serviceName: bigquery.googleapis.com
      methodSelectors:
      - method: "google.cloud.bigquery.v2.JobService.InsertJob"
      - method: "google.cloud.bigquery.v2.TableService.GetTable"
    resources:
    - "projects/${PROJECT_NUMBER}"
EOF
fi

# Update primary perimeter with ingress rules
print_info "Updating primary perimeter with ingress rules..."

# Apply admin ingress rules
if gcloud access-context-manager perimeters dry-run update "$PERIMETER_NAME" \
    --add-ingress-policies=/tmp/ingress_admin.yaml \
    --policy="$ACCESS_POLICY_NAME"; then
    print_success "Added admin ingress rules to perimeter"
else
    print_error "Failed to add admin ingress rules"
fi

# Apply on-premises app ingress rules (only if VPN is configured)
if [ -n "$ON_PREM_NETWORK_RANGE" ]; then
    if gcloud access-context-manager perimeters dry-run update "$PERIMETER_NAME" \
        --add-ingress-policies=/tmp/ingress_onprem_apps.yaml \
        --policy="$ACCESS_POLICY_NAME"; then
        print_success "Added on-premises app ingress rules to perimeter"
    else
        print_error "Failed to add on-premises app ingress rules"
    fi
else
    print_info "Skipping on-premises app ingress rules (no VPN configured)"
fi

# Configure egress rules (initially very restrictive)
print_info "Configuring egress rules..."

cat > /tmp/egress_rules.yaml <<EOF
egressPolicies:
- egressFrom:
    identityType: ANY_IDENTITY
  egressTo:
    operations:
    - serviceName: logging.googleapis.com
      methodSelectors:
      - method: "*"
    - serviceName: monitoring.googleapis.com
      methodSelectors:
      - method: "*"
    resources:
    - "projects/${LOG_PROJECT_NUMBER}"
EOF

# Apply egress rules
if gcloud access-context-manager perimeters dry-run update "$PERIMETER_NAME" \
    --add-egress-policies=/tmp/egress_rules.yaml \
    --policy="$ACCESS_POLICY_NAME"; then
    print_success "Added egress rules to perimeter"
else
    print_warning "Failed to add egress rules"
fi

# Display current perimeter configuration
print_info "Current perimeter configuration:"
gcloud access-context-manager perimeters dry-run describe "$PERIMETER_NAME" \
    --policy="$ACCESS_POLICY_NAME" \
    --format=yaml

# Clean up temporary files
rm -f /tmp/ingress_admin.yaml
rm -f /tmp/ingress_onprem_apps.yaml
rm -f /tmp/egress_rules.yaml

# Update state
save_state "INGRESS_RULES_CONFIGURED" "true"
save_state "INGRESS_RULES_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Ingress rules configured successfully!"
echo ""
echo "Ingress Rules Summary:"
echo "- Admin access from corporate networks"
if [ -n "$ON_PREM_NETWORK_RANGE" ]; then
    echo "- Admin access from on-premises networks"
    echo "- On-premises apps can access Storage and BigQuery"
fi
echo "- Minimal egress to logging/monitoring only"
echo ""
print_warning "IMPORTANT: Monitor dry-run logs before enforcement!"
echo ""
echo "To monitor violations:"
echo "gcloud logging read 'protoPayload.metadata.dryRun=true AND protoPayload.metadata.violationType=\"VPC_SERVICE_CONTROLS\"' \\"
echo "  --project=$PROJECT_ID --limit=50"
echo ""
echo "After 24-48 hours of monitoring, run: ./enforce-perimeters.sh"
