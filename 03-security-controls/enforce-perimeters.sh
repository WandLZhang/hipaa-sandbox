#!/bin/bash
# Enforce VPC Service Controls perimeters after dry-run analysis

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Enforcing VPC Service Controls"
echo "===================================="
echo ""

# Check prerequisites
if [ "$INGRESS_RULES_CONFIGURED" != "true" ]; then
    print_error "Ingress rules not configured. Run ./configure-ingress-rules.sh first."
    exit 1
fi

print_warning "CRITICAL: This will enforce VPC Service Controls!"
print_warning "================================================"
echo ""
echo "Before proceeding, ensure you have:"
echo "1. Monitored dry-run logs for at least 24-48 hours"
echo "2. Identified all legitimate access patterns"
echo "3. Updated ingress/egress rules as needed"
echo "4. Tested critical workflows"
echo ""
read -p "Have you completed dry-run analysis? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    print_error "Enforcement cancelled. Continue monitoring dry-run logs."
    exit 0
fi

echo ""
read -p "Are you sure you want to enforce VPC Service Controls? (yes/no): " CONFIRM_ENFORCE

if [ "$CONFIRM_ENFORCE" != "yes" ]; then
    print_error "Enforcement cancelled."
    exit 0
fi

# Enforce primary perimeter
print_info "Enforcing primary perimeter: $PERIMETER_NAME"

if gcloud access-context-manager perimeters dry-run enforce "$PERIMETER_NAME" \
    --policy="$ACCESS_POLICY_NAME"; then
    print_success "Primary perimeter enforced successfully"
else
    print_error "Failed to enforce primary perimeter"
    exit 1
fi

# Enforce research perimeter if it exists
if [ "$RESEARCH_PROJECT_CREATED" = "true" ] && [ -n "$RESEARCH_PERIMETER_NAME" ]; then
    print_info "Enforcing research perimeter: $RESEARCH_PERIMETER_NAME"
    
    if gcloud access-context-manager perimeters dry-run enforce "$RESEARCH_PERIMETER_NAME" \
        --policy="$ACCESS_POLICY_NAME"; then
        print_success "Research perimeter enforced successfully"
    else
        print_warning "Failed to enforce research perimeter"
    fi
fi

# Verify enforcement
print_info "Verifying perimeter enforcement..."

PERIMETER_STATUS=$(gcloud access-context-manager perimeters describe "$PERIMETER_NAME" \
    --policy="$ACCESS_POLICY_NAME" \
    --format="value(status.vpcAccessibleServices)")

if [ -n "$PERIMETER_STATUS" ]; then
    check_status "Perimeter is ENFORCED"
else
    check_status "Perimeter enforcement status unclear"
fi

# Update state
save_state "PERIMETERS_ENFORCED" "true"
save_state "PERIMETERS_ENFORCED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
save_state "PHASE_03_COMPLETE" "true"

echo ""
print_success "VPC Service Controls are now ENFORCED!"
echo ""
print_warning "IMPORTANT POST-ENFORCEMENT STEPS:"
echo "================================="
echo ""
echo "1. Monitor for access denials:"
echo "   gcloud logging read 'protoPayload.metadata.violationType=\"VPC_SERVICE_CONTROLS\"' \\"
echo "     --project=$PROJECT_ID --limit=50"
echo ""
echo "2. If legitimate access is blocked:"
echo "   - Update ingress/egress rules"
echo "   - Add service accounts to access levels"
echo "   - Adjust perimeter configuration"
echo ""
echo "3. Test all critical workflows immediately"
echo ""
echo "4. Have rollback plan ready if needed"
echo ""
print_success "Phase 03: Security Controls completed!"
echo ""
echo "Next phase: cd ../04-logging-monitoring && ./setup-logging-project.sh"
