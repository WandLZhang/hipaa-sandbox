#!/bin/bash
# Create VPC Service Controls perimeters for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Creating VPC Service Controls Perimeters"
echo "===================================="
echo ""

# Check prerequisites
if [ "$ACCESS_CONTEXT_CONFIGURED" != "true" ]; then
    print_error "Access Context not configured. Run ./setup-access-context.sh first."
    exit 1
fi

if [ -z "$ACCESS_POLICY_NAME" ]; then
    print_error "ACCESS_POLICY_NAME not found. Run ./setup-access-context.sh first."
    exit 1
fi

# Get project numbers
print_info "Getting project numbers..."

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
LOG_PROJECT_NUMBER=$(gcloud projects describe "$LOG_PROJECT_ID" --format="value(projectNumber)")
RESEARCH_PROJECT_NUMBER=""

if [ "$RESEARCH_PROJECT_CREATED" = "true" ]; then
    RESEARCH_PROJECT_NUMBER=$(gcloud projects describe "$RESEARCH_PROJECT_ID" --format="value(projectNumber)")
fi

# Function to create perimeter
create_perimeter() {
    local PERIMETER=$1
    local TITLE=$2
    local RESOURCES=$3
    local DRY_RUN=$4
    
    print_info "Creating perimeter: $PERIMETER (dry-run: $DRY_RUN)"
    
    # Check if perimeter already exists
    if gcloud access-context-manager perimeters describe "$PERIMETER" \
        --policy="$ACCESS_POLICY_NAME" &>/dev/null 2>&1; then
        print_warning "Perimeter already exists: $PERIMETER"
        return 0
    fi
    
    # Build command
    local CMD="gcloud access-context-manager perimeters create $PERIMETER"
    CMD="$CMD --title=\"$TITLE\""
    CMD="$CMD --resources=$RESOURCES"
    # Let Assured Workloads handle most service restrictions
    # Only restrict services that need additional controls beyond AW
    CMD="$CMD --restricted-services=cloudresourcemanager.googleapis.com,iamcredentials.googleapis.com"
    CMD="$CMD --perimeter-type=regular"
    CMD="$CMD --policy=$ACCESS_POLICY_NAME"
    
    if [ "$DRY_RUN" = "true" ]; then
        CMD="$CMD --dry-run"
    fi
    
    # Execute command
    if eval $CMD; then
        check_status "Created perimeter: $PERIMETER"
        return 0
    else
        check_status "Failed to create perimeter: $PERIMETER"
        return 1
    fi
}

# Create primary perimeter in dry-run mode
print_info "Creating primary secure perimeter in dry-run mode..."

RESOURCES="projects/$PROJECT_NUMBER"
# Include logging project in the perimeter
RESOURCES="$RESOURCES,projects/$LOG_PROJECT_NUMBER"

create_perimeter \
    "$PERIMETER_NAME" \
    "${ORGANIZATION_NAME} Health Sciences Secure Perimeter" \
    "$RESOURCES" \
    "true"

# Create research perimeter in dry-run mode (if research project exists)
if [ -n "$RESEARCH_PROJECT_NUMBER" ]; then
    print_info "Creating research perimeter in dry-run mode..."
    
    create_perimeter \
        "$RESEARCH_PERIMETER_NAME" \
        "${ORGANIZATION_NAME} Health Sciences Research Perimeter" \
        "projects/$RESEARCH_PROJECT_NUMBER" \
        "true"
fi

# Display perimeter status
print_info "VPC Service Controls perimeters:"
gcloud access-context-manager perimeters list \
    --policy="$ACCESS_POLICY_NAME" \
    --format="table(name,title,spec.resources[].list():label=RESOURCES)"

echo ""
print_warning "IMPORTANT: Perimeters created in DRY-RUN mode"
print_warning "==========================================="
echo ""
echo "Dry-run mode allows you to:"
echo "1. Test the configuration without enforcement"
echo "2. Monitor logs for potential violations"
echo "3. Adjust rules before enforcement"
echo ""
echo "Monitor dry-run logs for 24-48 hours before enforcement:"
echo ""
echo "gcloud logging read 'protoPayload.metadata.\"@type\"=\"type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata\"' \\"
echo "  --project=$PROJECT_ID \\"
echo "  --format=json"
echo ""

# Update state
save_state "PERIMETERS_CREATED" "true"
save_state "PERIMETERS_CREATED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "VPC Service Controls perimeters created in dry-run mode!"
echo ""
echo "Perimeters:"
echo "- $PERIMETER_NAME (Primary): Projects $PROJECT_ID, $LOG_PROJECT_ID"
if [ -n "$RESEARCH_PROJECT_NUMBER" ]; then
    echo "- $RESEARCH_PERIMETER_NAME (Research): Project $RESEARCH_PROJECT_ID"
fi
echo ""
echo "Next step: ./configure-ingress-rules.sh"
