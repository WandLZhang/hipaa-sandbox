#!/bin/bash
# Create projects for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Creating Projects"
echo "===================================="
echo ""

# Check prerequisites
if [ "$ASSURED_WORKLOADS_CONFIGURED" != "true" ]; then
    print_error "Assured Workloads not configured. Run ./create-folder.sh first."
    exit 1
fi

if [ -z "$FOLDER_ID" ]; then
    print_error "FOLDER_ID not found. Run ./create-folder.sh first."
    exit 1
fi

# Function to create project
create_project() {
    local PROJECT_ID=$1
    local PROJECT_NAME=$2
    local PROJECT_TYPE=$3
    
    print_info "Creating $PROJECT_TYPE project: $PROJECT_ID"
    
    # Check if project already exists
    if gcloud projects describe "$PROJECT_ID" &>/dev/null 2>&1; then
        print_warning "Project already exists: $PROJECT_ID"
        return 0
    fi
    
    # Create project
    if gcloud projects create "$PROJECT_ID" \
        --name="$PROJECT_NAME" \
        --folder="$FOLDER_ID"; then
        print_success "Created project: $PROJECT_ID"
    else
        print_error "Failed to create project: $PROJECT_ID"
        return 1
    fi
    
    # Link billing account
    print_info "Linking billing account to $PROJECT_ID"
    if gcloud beta billing projects link "$PROJECT_ID" \
        --billing-account="$BILLING_ACCOUNT_ID"; then
        check_status "Billing account linked"
    else
        print_error "Failed to link billing account"
        return 1
    fi
    
    return 0
}

# Create primary project
if create_project "$PROJECT_ID" "$PROJECT_NAME" "primary"; then
    save_state "PRIMARY_PROJECT_CREATED" "true"
else
    print_error "Failed to create primary project"
    exit 1
fi

# Create logging project
if create_project "$LOG_PROJECT_ID" "$LOG_PROJECT_NAME" "logging"; then
    save_state "LOGGING_PROJECT_CREATED" "true"
else
    print_error "Failed to create logging project"
    exit 1
fi

# Create research project (Phase 2)
print_info "Creating research project for Phase 2..."
if create_project "$RESEARCH_PROJECT_ID" "$RESEARCH_PROJECT_NAME" "research"; then
    save_state "RESEARCH_PROJECT_CREATED" "true"
else
    print_warning "Failed to create research project - can be created later in Phase 06"
fi

echo ""

# Set default project
print_info "Setting default project to: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# Display created projects
print_info "Projects created in folder $FOLDER_ID:"
gcloud projects list --filter="parent.id=$FOLDER_ID" \
    --format="table(projectId,name,projectNumber)"

# Update state
save_state "PROJECTS_CREATED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "All projects created successfully!"
echo ""
echo "Next step: ./enable-apis.sh"
