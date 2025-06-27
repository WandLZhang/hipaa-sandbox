#!/bin/bash
# Setup BigQuery datasets and basic DLP configuration for HIPAA compliance

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting up BigQuery & DLP Infrastructure"
echo "===================================="
echo ""

# Check prerequisites
if [ "$PERIMETER_BRIDGE_CONFIGURED" != "true" ]; then
    print_error "Perimeter bridge not configured. Run ./setup-perimeter-bridge.sh first."
    exit 1
fi

# Set project context to production first
gcloud config set project "$PROJECT_ID"

# Create raw data dataset in production project
print_info "Creating raw healthcare dataset in production project..."

RAW_DATASET="healthcare_raw"
if bq show --dataset "$PROJECT_ID:$RAW_DATASET" &>/dev/null 2>&1; then
    print_warning "Raw dataset already exists: $RAW_DATASET"
else
    if bq mk --dataset \
        --location="$LOCATION" \
        --description="Raw healthcare data with PHI - ${ORGANIZATION_NAME}" \
        --default_kms_key="projects/$PROJECT_ID/locations/$REGION/keyRings/$KMS_KEYRING_NAME/cryptoKeys/$KMS_KEY_DATABASE" \
        "$PROJECT_ID:$RAW_DATASET"; then
        print_success "Created raw dataset: $RAW_DATASET"
    else
        print_error "Failed to create raw dataset"
        exit 1
    fi
fi

# Create governance dataset for DLP findings
print_info "Creating governance dataset for DLP findings..."

GOVERNANCE_DATASET="data_governance"
if bq show --dataset "$PROJECT_ID:$GOVERNANCE_DATASET" &>/dev/null 2>&1; then
    print_warning "Governance dataset already exists: $GOVERNANCE_DATASET"
else
    if bq mk --dataset \
        --location="$LOCATION" \
        --description="Data governance and DLP scan results" \
        "$PROJECT_ID:$GOVERNANCE_DATASET"; then
        print_success "Created governance dataset: $GOVERNANCE_DATASET"
    else
        print_error "Failed to create governance dataset"
        exit 1
    fi
fi

# Switch to research project
gcloud config set project "$RESEARCH_PROJECT_ID"

# Create research dataset in research project
print_info "Creating research dataset in research project..."

RESEARCH_DATASET="healthcare_research"
if bq show --dataset "$RESEARCH_PROJECT_ID:$RESEARCH_DATASET" &>/dev/null 2>&1; then
    print_warning "Research dataset already exists: $RESEARCH_DATASET"
else
    if bq mk --dataset \
        --location="$LOCATION" \
        --description="De-identified healthcare data for research - ${ORGANIZATION_NAME}" \
        "$RESEARCH_PROJECT_ID:$RESEARCH_DATASET"; then
        print_success "Created research dataset: $RESEARCH_DATASET"
    else
        print_error "Failed to create research dataset"
        exit 1
    fi
fi

# Switch back to production project
gcloud config set project "$PROJECT_ID"

# Create DLP inspection templates
print_info "Creating DLP inspection templates for data discovery..."

# Create PHI detection template
cat > /tmp/phi_inspection_template.json <<EOF
{
  "displayName": "${ORGANIZATION_NAME} PHI Detection Template",
  "description": "Detects Protected Health Information (PHI) for HIPAA compliance",
  "inspectConfig": {
    "infoTypes": [
      {"name": "PERSON_NAME"},
      {"name": "US_SOCIAL_SECURITY_NUMBER"},
      {"name": "DATE_OF_BIRTH"},
      {"name": "US_DRIVERS_LICENSE_NUMBER"},
      {"name": "US_PASSPORT"},
      {"name": "US_HEALTHCARE_NPI"},
      {"name": "US_DEA_NUMBER"},
      {"name": "MEDICAL_RECORD_NUMBER"},
      {"name": "PHONE_NUMBER"},
      {"name": "EMAIL_ADDRESS"},
      {"name": "US_STATE"},
      {"name": "CREDIT_CARD_NUMBER"},
      {"name": "US_BANK_ROUTING_MICR"},
      {"name": "IP_ADDRESS"},
      {"name": "MAC_ADDRESS"},
      {"name": "GENERIC_ID"}
    ],
    "minLikelihood": "POSSIBLE",
    "limits": {
      "maxFindingsPerRequest": 100
    },
    "includeQuote": true
  }
}
EOF

# Create the PHI inspection template
PHI_TEMPLATE_ID="phi-detection-template"
if gcloud dlp inspect-templates create \
    --project="$PROJECT_ID" \
    --from-file=/tmp/phi_inspection_template.json \
    --template-id="$PHI_TEMPLATE_ID" 2>/dev/null; then
    print_success "Created PHI detection template"
else
    print_warning "PHI detection template may already exist"
fi

# Create PII detection template
cat > /tmp/pii_inspection_template.json <<EOF
{
  "displayName": "${ORGANIZATION_NAME} PII Detection Template",
  "description": "Detects Personally Identifiable Information (PII) for privacy compliance",
  "inspectConfig": {
    "infoTypes": [
      {"name": "PERSON_NAME"},
      {"name": "US_SOCIAL_SECURITY_NUMBER"},
      {"name": "US_DRIVERS_LICENSE_NUMBER"},
      {"name": "US_PASSPORT"},
      {"name": "PHONE_NUMBER"},
      {"name": "EMAIL_ADDRESS"},
      {"name": "STREET_ADDRESS"},
      {"name": "DATE_OF_BIRTH"},
      {"name": "CREDIT_CARD_NUMBER"},
      {"name": "US_BANK_ROUTING_MICR"},
      {"name": "IBAN_CODE"},
      {"name": "IP_ADDRESS"},
      {"name": "URL"},
      {"name": "DOMAIN_NAME"}
    ],
    "minLikelihood": "LIKELY",
    "limits": {
      "maxFindingsPerRequest": 100
    },
    "includeQuote": true
  }
}
EOF

# Create the PII template
PII_TEMPLATE_ID="pii-detection-template"
if gcloud dlp inspect-templates create \
    --project="$PROJECT_ID" \
    --from-file=/tmp/pii_inspection_template.json \
    --template-id="$PII_TEMPLATE_ID" 2>/dev/null; then
    print_success "Created PII detection template"
else
    print_warning "PII detection template may already exist"
fi

# Clean up template files
rm -f /tmp/phi_inspection_template.json
rm -f /tmp/pii_inspection_template.json

# Grant cross-project permissions to service account
print_info "Granting cross-project permissions..."

# Grant BigQuery data viewer on raw data
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEIDENTIFY_SA_EMAIL}" \
    --role="roles/bigquery.dataViewer" \
    --condition="expression=resource.name.startsWith('projects/$PROJECT_ID/datasets/$RAW_DATASET'),title=RawDataAccess"

# Grant BigQuery data editor on research data
gcloud projects add-iam-policy-binding "$RESEARCH_PROJECT_ID" \
    --member="serviceAccount:${DEIDENTIFY_SA_EMAIL}" \
    --role="roles/bigquery.dataEditor" \
    --condition="expression=resource.name.startsWith('projects/$RESEARCH_PROJECT_ID/datasets/$RESEARCH_DATASET'),title=ResearchDataAccess"

# Grant DLP reader access
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEIDENTIFY_SA_EMAIL}" \
    --role="roles/dlp.reader"

# Update state
save_state "BIGQUERY_DLP_CONFIGURED" "true"
save_state "RAW_DATASET" "$RAW_DATASET"
save_state "GOVERNANCE_DATASET" "$GOVERNANCE_DATASET"
save_state "RESEARCH_DATASET" "$RESEARCH_DATASET"
save_state "DLP_PHI_TEMPLATE" "$PHI_TEMPLATE_ID"
save_state "DLP_PII_TEMPLATE" "$PII_TEMPLATE_ID"
save_state "BIGQUERY_DLP_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "BigQuery and DLP infrastructure configured!"
echo ""
echo "Datasets created:"
echo "- Raw PHI data: $PROJECT_ID:$RAW_DATASET"
echo "- DLP governance: $PROJECT_ID:$GOVERNANCE_DATASET"
echo "- Research data: $RESEARCH_PROJECT_ID:$RESEARCH_DATASET"
echo ""
echo "DLP templates created:"
echo "- PHI detection: projects/$PROJECT_ID/inspectTemplates/$PHI_TEMPLATE_ID"
echo "- PII detection: projects/$PROJECT_ID/inspectTemplates/$PII_TEMPLATE_ID"
echo ""
echo "Service account permissions granted:"
echo "- ${DEIDENTIFY_SA_EMAIL}"
echo ""
echo "Example DLP scan command:"
echo "gcloud dlp jobs create \\"
echo "  --project=$PROJECT_ID \\"
echo "  --location=global \\"
echo "  --inspect-bigquery-table \\"
echo "  --dataset-id=$RAW_DATASET \\"
echo "  --table-id=YOUR_TABLE_NAME \\"
echo "  --inspect-template=projects/$PROJECT_ID/inspectTemplates/$PHI_TEMPLATE_ID"
echo ""
echo "Next steps:"
echo "1. Load PHI data into BigQuery (see README.md)"
echo "2. Run DLP scans to identify sensitive columns"
echo "3. Create de-identified views for researchers"
echo ""
echo "See README.md in the root directory for detailed instructions"
