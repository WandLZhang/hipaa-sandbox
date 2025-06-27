#!/bin/bash
# Configure centralized log sinks for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Configuring Centralized Log Sinks"
echo "===================================="
echo ""

# Check prerequisites
if [ "$LOGGING_INFRASTRUCTURE_READY" != "true" ]; then
    print_error "Logging infrastructure not ready. Run ./setup-logging-project.sh first."
    exit 1
fi

# Create log filter for audit logs
LOG_FILTER='protoPayload.@type="type.googleapis.com/google.cloud.audit.AuditLog"
AND (
    logName:"cloudaudit.googleapis.com%2Factivity"
    OR logName:"cloudaudit.googleapis.com%2Fdata_access"
    OR logName:"cloudaudit.googleapis.com%2Fsystem_event"
    OR logName:"cloudaudit.googleapis.com%2Fpolicy"
)
AND resource.labels.folder_id="'${FOLDER_ID}'"'

# Create BigQuery log sink
print_info "Creating log sink to BigQuery..."

SINK_NAME_BQ="${LOG_SINK_NAME}-bigquery"

# Check if sink already exists
if gcloud logging sinks describe "$SINK_NAME_BQ" \
    --organization="$ORG_ID" &>/dev/null 2>&1; then
    print_warning "BigQuery log sink already exists: $SINK_NAME_BQ"
else
    # Create sink
    BQ_SINK_SA=$(gcloud logging sinks create "$SINK_NAME_BQ" \
        "bigquery.googleapis.com/projects/$LOG_PROJECT_ID/datasets/$LOG_DATASET_NAME" \
        --organization="$ORG_ID" \
        --log-filter="$LOG_FILTER" \
        --format="value(writerIdentity)")
    
    if [ $? -eq 0 ]; then
        print_success "Created BigQuery log sink: $SINK_NAME_BQ"
        save_state "BQ_SINK_SA" "$BQ_SINK_SA"
    else
        print_error "Failed to create BigQuery log sink"
        exit 1
    fi
fi

# Get sink service account if not saved
if [ -z "$BQ_SINK_SA" ]; then
    BQ_SINK_SA=$(gcloud logging sinks describe "$SINK_NAME_BQ" \
        --organization="$ORG_ID" \
        --format="value(writerIdentity)")
fi

# Grant permissions to BigQuery sink
print_info "Granting permissions to BigQuery sink service account..."

if gcloud projects add-iam-policy-binding "$LOG_PROJECT_ID" \
    --member="$BQ_SINK_SA" \
    --role="roles/bigquery.dataEditor" \
    --condition=None; then
    print_success "Granted BigQuery permissions"
else
    print_warning "Failed to grant BigQuery permissions"
fi

# Create Cloud Storage log sink
print_info "Creating log sink to Cloud Storage..."

SINK_NAME_GCS="${LOG_SINK_NAME}-storage"

# Check if sink already exists
if gcloud logging sinks describe "$SINK_NAME_GCS" \
    --organization="$ORG_ID" &>/dev/null 2>&1; then
    print_warning "Storage log sink already exists: $SINK_NAME_GCS"
else
    # Create sink
    GCS_SINK_SA=$(gcloud logging sinks create "$SINK_NAME_GCS" \
        "storage.googleapis.com/$LOG_BUCKET_NAME" \
        --organization="$ORG_ID" \
        --log-filter="$LOG_FILTER" \
        --format="value(writerIdentity)")
    
    if [ $? -eq 0 ]; then
        print_success "Created Storage log sink: $SINK_NAME_GCS"
        save_state "GCS_SINK_SA" "$GCS_SINK_SA"
    else
        print_error "Failed to create Storage log sink"
        exit 1
    fi
fi

# Get sink service account if not saved
if [ -z "$GCS_SINK_SA" ]; then
    GCS_SINK_SA=$(gcloud logging sinks describe "$SINK_NAME_GCS" \
        --organization="$ORG_ID" \
        --format="value(writerIdentity)")
fi

# Grant permissions to Storage sink
print_info "Granting permissions to Storage sink service account..."

if gsutil iam ch "$GCS_SINK_SA:objectCreator" "gs://$LOG_BUCKET_NAME"; then
    print_success "Granted Storage permissions"
else
    print_warning "Failed to grant Storage permissions"
fi

# Create additional project-level sinks for VPC Service Controls logs
print_info "Creating project-level sink for VPC-SC logs..."

VPCSC_SINK_NAME="vpc-sc-violations"

# Set project context
gcloud config set project "$PROJECT_ID"

if gcloud logging sinks describe "$VPCSC_SINK_NAME" &>/dev/null 2>&1; then
    print_warning "VPC-SC log sink already exists: $VPCSC_SINK_NAME"
else
    # Create sink for VPC-SC violations
    if gcloud logging sinks create "$VPCSC_SINK_NAME" \
        "bigquery.googleapis.com/projects/$LOG_PROJECT_ID/datasets/$LOG_DATASET_NAME" \
        --log-filter='protoPayload.metadata.@type="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"'; then
        print_success "Created VPC-SC violations sink"
    else
        print_warning "Failed to create VPC-SC violations sink"
    fi
fi

# List all sinks
print_info "Organization-level log sinks:"
gcloud logging sinks list --organization="$ORG_ID" \
    --format="table(name,destination,filter)"

echo ""
print_info "Project-level log sinks:"
gcloud logging sinks list --project="$PROJECT_ID" \
    --format="table(name,destination)"

# Update state
save_state "LOG_SINKS_CONFIGURED" "true"
save_state "LOG_SINKS_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Log sinks configured successfully!"
echo ""
echo "Log Flow:"
echo "- All audit logs from folder $FOLDER_ID"
echo "  → BigQuery: $LOG_PROJECT_ID:$LOG_DATASET_NAME (for analysis)"
echo "  → Storage: gs://$LOG_BUCKET_NAME/ (for 6-year retention)"
echo "- VPC-SC violations → BigQuery for monitoring"
echo ""
echo "Next step: ./enable-audit-logs.sh"
