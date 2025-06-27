#!/bin/bash
# Create folder structure for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Creating Folder Structure"
echo "===================================="
echo ""

# Check if setup was validated
if [ "$SETUP_VALIDATED" != "true" ]; then
    print_error "Setup not validated. Please run Phase 00 first."
    exit 1
fi

# Check if folder already exists
print_info "Checking for existing folder..."

EXISTING_FOLDERS=$(gcloud resource-manager folders list \
    --organization="${ORG_ID}" \
    --filter="displayName='${FOLDER_DISPLAY_NAME}'" \
    --format="value(name)" 2>/dev/null)

if [ -n "$EXISTING_FOLDERS" ]; then
    print_warning "Folder '${FOLDER_DISPLAY_NAME}' already exists"
    FOLDER_ID=$(echo "$EXISTING_FOLDERS" | head -n1 | cut -d'/' -f2)
    print_info "Using existing folder ID: $FOLDER_ID"
else
    # Create new folder
    print_info "Creating new folder: ${FOLDER_DISPLAY_NAME}"
    
    FOLDER_RESPONSE=$(gcloud resource-manager folders create \
        --display-name="${FOLDER_DISPLAY_NAME}" \
        --organization="${ORG_ID}" \
        --format="value(name)" 2>&1)
    
    if [ $? -eq 0 ]; then
        FOLDER_ID=$(echo "$FOLDER_RESPONSE" | cut -d'/' -f2)
        print_success "Created folder with ID: $FOLDER_ID"
    else
        print_error "Failed to create folder"
        echo "$FOLDER_RESPONSE"
        exit 1
    fi
fi

# Save folder ID to state
save_state "FOLDER_ID" "$FOLDER_ID"
echo "export FOLDER_ID=\"$FOLDER_ID\"" >> ../config/environment.conf

# Display folder details
print_info "Folder details:"
gcloud resource-manager folders describe "folders/$FOLDER_ID"

echo ""
print_warning "MANUAL STEP REQUIRED!"
print_warning "========================="
echo ""
echo "You must now create the Assured Workloads environment:"
echo ""
echo "1. Go to: https://console.cloud.google.com/compliance/assuredworkloads"
echo "2. Click 'Create workload'"
echo "3. Select this folder: ${FOLDER_DISPLAY_NAME} (ID: $FOLDER_ID)"
echo "4. Choose compliance regime: FedRAMP Moderate"
echo "5. Review and accept the controls"
echo "6. Complete the setup wizard"
echo ""
echo "This will apply organization policies that:"
echo "- Restrict services to FedRAMP-approved only"
echo "- Enforce data residency in US regions"
echo "- Apply personnel access controls"
echo "- Enable compliance monitoring"
echo ""
read -p "Press ENTER when you have completed the Assured Workloads setup..."

# Verify Assured Workloads was applied
print_info "Verifying Assured Workloads configuration..."

# Check for organization policies
POLICIES=$(gcloud resource-manager org-policies list \
    --folder="$FOLDER_ID" \
    --format="value(constraint)" 2>/dev/null)

if echo "$POLICIES" | grep -q "constraints/gcp.restrictServiceUsage"; then
    check_status "Service restriction policy detected"
else
    print_warning "Service restriction policy not detected"
    print_warning "Assured Workloads may not be properly configured"
fi

if echo "$POLICIES" | grep -q "constraints/gcp.resourceLocations"; then
    check_status "Resource location policy detected"
else
    print_warning "Resource location policy not detected"
    print_warning "Assured Workloads may not be properly configured"
fi

# Update state
save_state "ASSURED_WORKLOADS_CONFIGURED" "true"
save_state "FOLDER_CREATED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Folder structure created successfully!"
echo ""
echo "Next step: ./create-projects.sh"
