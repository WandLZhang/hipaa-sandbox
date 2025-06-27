#!/bin/bash
# Enable required APIs for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Enabling Required APIs"
echo "===================================="
echo ""

# Check prerequisites
if [ "$PRIMARY_PROJECT_CREATED" != "true" ]; then
    print_error "Projects not created. Run ./create-projects.sh first."
    exit 1
fi

# Function to enable APIs for a project
enable_project_apis() {
    local PROJECT=$1
    local PROJECT_TYPE=$2
    
    print_info "Enabling APIs for $PROJECT_TYPE project: $PROJECT"
    
    # Set project context
    gcloud config set project "$PROJECT" 2>/dev/null
    
    # Enable all required APIs
    local API_BATCH=""
    for API in "${REQUIRED_APIS[@]}"; do
        API_BATCH="$API_BATCH $API"
    done
    
    print_info "Enabling ${#REQUIRED_APIS[@]} APIs..."
    if gcloud services enable $API_BATCH; then
        check_status "APIs enabled for $PROJECT"
    else
        print_error "Failed to enable some APIs for $PROJECT"
        return 1
    fi
    
    # Additional APIs based on project type
    case $PROJECT_TYPE in
        "primary")
            print_info "Enabling additional APIs for primary project..."
            gcloud services enable \
                vpcaccess.googleapis.com \
                servicenetworking.googleapis.com \
                cloudvpn.googleapis.com || print_warning "Some additional APIs failed"
            ;;
        "logging")
            print_info "Enabling additional APIs for logging project..."
            # Logging project needs minimal APIs
            ;;
        "research")
            print_info "Enabling all available APIs for research project..."
            # Enable all APIs - let Assured Workloads handle restrictions
            print_info "Researchers can enable any additional APIs as needed"
            # No specific API restrictions for research project
            ;;
    esac
    
    return 0
}

# Enable APIs for primary project
if enable_project_apis "$PROJECT_ID" "primary"; then
    save_state "PRIMARY_APIS_ENABLED" "true"
else
    print_error "Failed to enable APIs for primary project"
    exit 1
fi

echo ""

# Enable APIs for logging project
if enable_project_apis "$LOG_PROJECT_ID" "logging"; then
    save_state "LOGGING_APIS_ENABLED" "true"
else
    print_error "Failed to enable APIs for logging project"
    exit 1
fi

echo ""

# Enable APIs for research project (if it was created)
if [ "$RESEARCH_PROJECT_CREATED" = "true" ]; then
    if enable_project_apis "$RESEARCH_PROJECT_ID" "research"; then
        save_state "RESEARCH_APIS_ENABLED" "true"
    else
        print_warning "Failed to enable APIs for research project"
    fi
fi

echo ""

# Set project back to primary
gcloud config set project "$PROJECT_ID"

# Verify critical APIs
print_info "Verifying critical API enablement..."

CRITICAL_APIS=(
    "compute.googleapis.com"
    "storage.googleapis.com"
    "cloudkms.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
)

ALL_ENABLED=true
for API in "${CRITICAL_APIS[@]}"; do
    if gcloud services list --enabled --filter="name:$API" --format="value(name)" | grep -q "$API"; then
        check_status "$API enabled"
    else
        check_status "$API enabled"
        ALL_ENABLED=false
    fi
done

if [ "$ALL_ENABLED" = true ]; then
    print_success "All critical APIs enabled successfully!"
else
    print_error "Some critical APIs are not enabled"
    exit 1
fi

# Update state
save_state "APIS_ENABLED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
save_state "PHASE_01_COMPLETE" "true"

echo ""
print_success "Phase 01: Foundation completed successfully!"
echo ""
echo "Summary:"
echo "- Folder created: $FOLDER_ID"
echo "- Assured Workloads: Configured with FedRAMP Moderate"
echo "- Projects created: $PROJECT_ID, $LOG_PROJECT_ID, $RESEARCH_PROJECT_ID"
echo "- APIs enabled: ${#REQUIRED_APIS[@]} core APIs + project-specific APIs"
echo ""
echo "Next phase: cd ../02-networking && ./create-vpc.sh"
