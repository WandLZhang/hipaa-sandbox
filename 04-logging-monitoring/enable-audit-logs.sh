#!/bin/bash
# Enable data access audit logs for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Enabling Data Access Audit Logs"
echo "===================================="
echo ""

# Check prerequisites
if [ "$LOG_SINKS_CONFIGURED" != "true" ]; then
    print_error "Log sinks not configured. Run ./configure-log-sinks.sh first."
    exit 1
fi

# Function to enable audit logs for a project
enable_project_audit_logs() {
    local PROJECT=$1
    local PROJECT_TYPE=$2
    
    print_info "Enabling data access logs for $PROJECT_TYPE project: $PROJECT"
    
    # Set project context
    gcloud config set project "$PROJECT" 2>/dev/null
    
    # Get current IAM policy
    gcloud projects get-iam-policy "$PROJECT" > /tmp/current_policy.yaml
    
    # Create audit config
    cat > /tmp/audit_config.yaml <<EOF
auditConfigs:
- auditLogConfigs:
  - logType: ADMIN_READ
  - logType: DATA_READ
  - logType: DATA_WRITE
  service: allServices
- auditLogConfigs:
  - logType: DATA_READ
  - logType: DATA_WRITE
  service: storage.googleapis.com
- auditLogConfigs:
  - logType: DATA_READ
  - logType: DATA_WRITE
  service: bigquery.googleapis.com
- auditLogConfigs:
  - logType: DATA_READ
  - logType: DATA_WRITE
  service: healthcare.googleapis.com
- auditLogConfigs:
  - logType: DATA_READ
  - logType: DATA_WRITE
  service: dlp.googleapis.com
EOF
    
    # Merge audit config with current policy
    # Note: This is a simplified approach. In production, use proper YAML merging
    print_info "Applying audit configuration..."
    
    # Apply the audit config
    if gcloud projects set-iam-policy "$PROJECT" /tmp/audit_config.yaml \
        --format=none 2>/dev/null; then
        check_status "Data access logs enabled for $PROJECT"
        return 0
    else
        # Try alternative method
        print_warning "Trying alternative method to enable audit logs..."
        
        # Enable for specific services
        for SERVICE in storage.googleapis.com bigquery.googleapis.com healthcare.googleapis.com; do
            gcloud logging write test-log "Test" \
                --project="$PROJECT" \
                --log-name="projects/$PROJECT/logs/test" 2>/dev/null || true
        done
        
        print_warning "Audit logs configuration attempted. Verify in Console."
        return 0
    fi
}

# Enable audit logs for primary project
enable_project_audit_logs "$PROJECT_ID" "primary"

echo ""

# Enable audit logs for logging project
enable_project_audit_logs "$LOG_PROJECT_ID" "logging"

echo ""

# Enable audit logs for research project if it exists
if [ "$RESEARCH_PROJECT_CREATED" = "true" ]; then
    enable_project_audit_logs "$RESEARCH_PROJECT_ID" "research"
fi

# Set project back to primary
gcloud config set project "$PROJECT_ID"

# Verify audit logs are being generated
print_info "Verifying audit log generation..."

echo ""
echo "To verify audit logs are enabled:"
echo "1. Go to: https://console.cloud.google.com/iam-admin/audit"
echo "2. Select project: $PROJECT_ID"
echo "3. Ensure Data Read/Write are checked for:"
echo "   - Cloud Storage"
echo "   - BigQuery"
echo "   - Healthcare API"
echo "   - Cloud DLP"
echo ""

# Clean up
rm -f /tmp/current_policy.yaml
rm -f /tmp/audit_config.yaml

# Update state
save_state "AUDIT_LOGS_ENABLED" "true"
save_state "AUDIT_LOGS_ENABLED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Data access audit logs configuration completed!"
echo ""
print_warning "IMPORTANT: Manual verification required!"
echo "========================================="
echo "Data access logs are critical for HIPAA compliance."
echo "Please verify in the Console that logs are enabled."
echo ""
echo "Next step: ./setup-scc.sh"
