#!/bin/bash
# Set up centralized logging project for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting Up Logging Project"
echo "===================================="
echo ""

# Check prerequisites
if [ "$PHASE_03_COMPLETE" != "true" ]; then
    print_error "Phase 03 not complete. Please complete security controls setup first."
    exit 1
fi

# Check if logging project already exists
if [ "$LOGGING_PROJECT_CREATED" = "true" ]; then
    print_info "Logging project already created: $LOG_PROJECT_ID"
else
    print_error "Logging project not found. It should have been created in Phase 01."
    print_error "Please check Phase 01 completion."
    exit 1
fi

# Set project context
gcloud config set project "$LOG_PROJECT_ID"

# Create BigQuery dataset for logs
print_info "Creating BigQuery dataset for log analysis..."

if bq show --dataset "$LOG_PROJECT_ID:$LOG_DATASET_NAME" &>/dev/null 2>&1; then
    print_warning "BigQuery dataset already exists: $LOG_DATASET_NAME"
else
    if bq mk --dataset \
        --location="$LOCATION" \
        --description="Centralized audit log storage for ${ORGANIZATION_NAME} Health Sciences" \
        "$LOG_PROJECT_ID:$LOG_DATASET_NAME"; then
        print_success "Created BigQuery dataset: $LOG_DATASET_NAME"
    else
        print_error "Failed to create BigQuery dataset"
        exit 1
    fi
fi

# Configure dataset description
print_info "Configuring BigQuery dataset settings..."

bq update \
    --description="Centralized audit log storage for ${ORGANIZATION_NAME} Health Sciences - Indefinite retention" \
    "$LOG_PROJECT_ID:$LOG_DATASET_NAME"

# Create Cloud Storage bucket for long-term log retention
print_info "Creating Cloud Storage bucket for log archival..."

# Generate unique bucket name if not set
if [ -z "$LOG_BUCKET_NAME" ] || [[ "$LOG_BUCKET_NAME" == *"RANDOM"* ]]; then
    LOG_BUCKET_NAME="${ORGANIZATION_SHORT}-health-audit-logs-$(date +%s)"
    save_state "LOG_BUCKET_NAME" "$LOG_BUCKET_NAME"
fi

if gsutil ls -b "gs://$LOG_BUCKET_NAME" &>/dev/null 2>&1; then
    print_warning "Storage bucket already exists: $LOG_BUCKET_NAME"
else
    if gsutil mb -p "$LOG_PROJECT_ID" \
        -c STANDARD \
        -l "$LOCATION" \
        -b on \
        "gs://$LOG_BUCKET_NAME/"; then
        print_success "Created storage bucket: $LOG_BUCKET_NAME"
    else
        print_error "Failed to create storage bucket"
        exit 1
    fi
fi

# Optional: Set retention policy for compliance
# NOTE: By default, logs are kept indefinitely. Uncomment below to enforce retention.
print_info "Retention policy configuration..."
echo ""
echo "By default, audit logs will be kept indefinitely."
echo "For HIPAA compliance, you may want to set a minimum 6-year retention."
echo ""
read -p "Would you like to set a retention policy? (yes/no): " SET_RETENTION

if [ "$SET_RETENTION" = "yes" ]; then
    echo ""
    echo "Common retention periods:"
    echo "  - 6y  : HIPAA minimum requirement"
    echo "  - 7y  : Common healthcare standard"
    echo "  - 10y : Extended retention for research"
    echo ""
    read -p "Enter retention period (e.g., 6y, 7y, 10y): " RETENTION_PERIOD
    
    if gsutil retention set "$RETENTION_PERIOD" "gs://$LOG_BUCKET_NAME/"; then
        print_success "Set $RETENTION_PERIOD retention policy"
        save_state "LOG_RETENTION_PERIOD" "$RETENTION_PERIOD"
        
        # Offer to lock the retention policy
        echo ""
        print_warning "WARNING: Bucket lock makes the retention policy PERMANENT!"
        print_warning "Once locked, objects cannot be deleted until retention expires."
        print_warning "This is recommended for compliance but cannot be undone."
        echo ""
        read -p "Enable bucket lock for immutable retention? (yes/no): " CONFIRM_LOCK
        
        if [ "$CONFIRM_LOCK" = "yes" ]; then
            if gsutil retention lock "gs://$LOG_BUCKET_NAME/"; then
                print_success "Retention policy locked (immutable)"
                save_state "BUCKET_LOCK_ENABLED" "true"
            else
                print_error "Failed to lock retention policy"
            fi
        else
            print_info "Bucket lock not enabled. Retention policy can be modified."
        fi
    else
        print_error "Failed to set retention policy"
    fi
else
    print_info "No retention policy set. Logs will be kept indefinitely."
fi

# Uncomment below to set retention policy without prompting:
# gsutil retention set 6y "gs://$LOG_BUCKET_NAME/"
# gsutil retention lock "gs://$LOG_BUCKET_NAME/"  # WARNING: This is permanent!

# Set bucket lifecycle rules
print_info "Configuring bucket lifecycle rules..."

cat > /tmp/lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {
          "type": "SetStorageClass",
          "storageClass": "NEARLINE"
        },
        "condition": {
          "age": 90,
          "matchesStorageClass": ["STANDARD"]
        }
      },
      {
        "action": {
          "type": "SetStorageClass",
          "storageClass": "COLDLINE"
        },
        "condition": {
          "age": 365,
          "matchesStorageClass": ["NEARLINE"]
        }
      },
      {
        "action": {
          "type": "SetStorageClass",
          "storageClass": "ARCHIVE"
        },
        "condition": {
          "age": 1095,
          "matchesStorageClass": ["COLDLINE"]
        }
      }
    ]
  }
}
EOF

if gsutil lifecycle set /tmp/lifecycle.json "gs://$LOG_BUCKET_NAME/"; then
    print_success "Configured lifecycle rules for cost optimization"
else
    print_warning "Failed to set lifecycle rules"
fi

# Clean up
rm -f /tmp/lifecycle.json

# Set default project back
gcloud config set project "$PROJECT_ID"

# Update state
save_state "LOGGING_INFRASTRUCTURE_READY" "true"
save_state "LOGGING_SETUP_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Logging infrastructure configured!"
echo ""
echo "Summary:"
echo "- BigQuery dataset: $LOG_PROJECT_ID:$LOG_DATASET_NAME"
echo "- Storage bucket: gs://$LOG_BUCKET_NAME/"
if [ -n "$LOG_RETENTION_PERIOD" ]; then
    echo "- Retention: $LOG_RETENTION_PERIOD"
    if [ "$BUCKET_LOCK_ENABLED" = "true" ]; then
        echo "- Bucket lock: ENABLED (immutable)"
    fi
else
    echo "- Retention: Indefinite (no automatic deletion)"
fi
echo "- Lifecycle: Automatic storage class transitions for cost savings"
echo ""
echo "Next step: ./configure-log-sinks.sh"
