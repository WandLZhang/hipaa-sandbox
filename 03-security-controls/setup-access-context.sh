#!/bin/bash
# Set up Access Context Manager for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting up Access Context Manager"
echo "===================================="
echo ""

# Check prerequisites
if [ "$PHASE_02_COMPLETE" != "true" ]; then
    print_error "Phase 02 not complete. Please complete networking setup first."
    exit 1
fi

# Get or create access policy
print_info "Checking for existing access policy..."

# Check if we already have an access policy
if [ -n "$ACCESS_POLICY_NAME" ]; then
    print_info "Using existing access policy: $ACCESS_POLICY_NAME"
else
    # Check for existing policy
    EXISTING_POLICY=$(gcloud access-context-manager policies list \
        --filter="title:${ACCESS_POLICY_TITLE}" \
        --format="value(name)" 2>/dev/null | head -n1)
    
    if [ -n "$EXISTING_POLICY" ]; then
        ACCESS_POLICY_NAME=$EXISTING_POLICY
        print_info "Found existing policy: $ACCESS_POLICY_NAME"
    else
        # Create new access policy
        print_info "Creating new access policy: $ACCESS_POLICY_TITLE"
        
        ACCESS_POLICY_NAME=$(gcloud access-context-manager policies create \
            --title="${ACCESS_POLICY_TITLE}" \
            --organization="${ORG_ID}" \
            --format="value(name)" 2>&1)
        
        if [ $? -eq 0 ]; then
            print_success "Access policy created: $ACCESS_POLICY_NAME"
        else
            print_error "Failed to create access policy"
            echo "$ACCESS_POLICY_NAME"
            exit 1
        fi
    fi
    
    # Save to state and environment
    save_state "ACCESS_POLICY_NAME" "$ACCESS_POLICY_NAME"
    echo "export ACCESS_POLICY_NAME=\"$ACCESS_POLICY_NAME\"" >> ../config/environment.conf
fi

# Function to create access level
create_access_level() {
    local LEVEL_NAME=$1
    local LEVEL_TITLE=$2
    local LEVEL_FILE=$3
    
    print_info "Creating access level: $LEVEL_NAME"
    
    # Check if level already exists
    if gcloud access-context-manager levels describe "$LEVEL_NAME" \
        --policy="$ACCESS_POLICY_NAME" &>/dev/null 2>&1; then
        print_warning "Access level already exists: $LEVEL_NAME"
        return 0
    fi
    
    # Create access level
    if gcloud access-context-manager levels create "$LEVEL_NAME" \
        --title="$LEVEL_TITLE" \
        --basic-level-spec="$LEVEL_FILE" \
        --policy="$ACCESS_POLICY_NAME"; then
        check_status "Created access level: $LEVEL_NAME"
        return 0
    else
        check_status "Failed to create access level: $LEVEL_NAME"
        return 1
    fi
}

# Create on-premises network access level (if VPN is configured)
if [ -n "$ON_PREM_NETWORK_RANGE" ]; then
    print_info "Configuring on-premises network access level..."

    cat > /tmp/on_prem_network.yaml <<EOF
- ipSubnetworks:
  - ${ON_PREM_NETWORK_RANGE}
EOF

    create_access_level \
        "on_prem_network" \
        "On-Premises Network Access" \
        "/tmp/on_prem_network.yaml"
else
    print_info "Skipping on-premises network access level (no VPN configured)"
fi

# Create corporate network access level
print_info "Configuring corporate network access level..."

# Convert comma-separated IP ranges to YAML format
CORP_IPS_YAML=$(echo "$CORPORATE_IP_RANGES" | tr ',' '\n' | sed 's/^/  - /')

cat > /tmp/corp_network.yaml <<EOF
- ipSubnetworks:
$CORP_IPS_YAML
EOF

create_access_level \
    "corp_network" \
    "Corporate Network Access" \
    "/tmp/corp_network.yaml"

# Create trusted users access level (optional)
print_info "Creating trusted users access level..."

cat > /tmp/trusted_users.yaml <<EOF
- members:
  - group:${ADMIN_GROUP}
  - group:${SECURITY_TEAM_GROUP}
EOF

create_access_level \
    "trusted_users" \
    "Trusted Organization Users" \
    "/tmp/trusted_users.yaml" || print_warning "Could not create trusted users level"

# List all access levels
print_info "Access levels configured:"
gcloud access-context-manager levels list \
    --policy="$ACCESS_POLICY_NAME" \
    --format="table(name,title)"

# Clean up temporary files
rm -f /tmp/on_prem_network.yaml
rm -f /tmp/corp_network.yaml
rm -f /tmp/trusted_users.yaml

# Update state
save_state "ACCESS_CONTEXT_CONFIGURED" "true"
save_state "ACCESS_LEVELS_CREATED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Access Context Manager configured successfully!"
echo ""
echo "Access Levels Created:"
if [ -n "$ON_PREM_NETWORK_RANGE" ]; then
    echo "- on_prem_network: Allows access from $ON_PREM_NETWORK_RANGE"
fi
echo "- corp_network: Allows access from corporate public IPs"
echo "- trusted_users: Allows specific users/groups (optional)"
echo ""
echo "Next step: ./create-perimeters.sh"
