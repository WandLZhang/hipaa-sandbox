#!/bin/bash
# Set up perimeter bridge for secure data transfer between perimeters

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting up Perimeter Bridge"
echo "===================================="
echo ""

# Check prerequisites
if [ "$PHASE_05_COMPLETE" != "true" ]; then
    print_error "Phase 05 not complete. Please complete data security setup first."
    exit 1
fi

# Check if research project exists
if [ "$RESEARCH_PROJECT_CREATED" != "true" ]; then
    print_error "Research project not created. Cannot set up perimeter bridge."
    print_error "The research project should have been created in Phase 01."
    exit 1
fi

# Check if perimeters are enforced
if [ "$PERIMETERS_ENFORCED" != "true" ]; then
    print_warning "VPC Service Controls not enforced. Bridge will be created but not active."
fi

# Get project numbers
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
RESEARCH_PROJECT_NUMBER=$(gcloud projects describe "$RESEARCH_PROJECT_ID" --format="value(projectNumber)")

# Create service account for cross-perimeter data transfers
print_info "Creating service account for cross-perimeter BigQuery transfers..."

DEIDENTIFY_SA_NAME="bigquery-transfer"
DEIDENTIFY_SA_EMAIL="${DEIDENTIFY_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$DEIDENTIFY_SA_EMAIL" &>/dev/null 2>&1; then
    print_warning "BigQuery transfer service account already exists"
else
    if gcloud iam service-accounts create "$DEIDENTIFY_SA_NAME" \
        --display-name="BigQuery Cross-Perimeter Transfer" \
        --description="Service account for transferring data between perimeters via BigQuery"; then
        print_success "Created BigQuery transfer service account"
    else
        print_error "Failed to create service account"
        exit 1
    fi
fi

# Grant necessary permissions to the service account
print_info "Granting permissions to BigQuery transfer service account..."

# Permissions in primary project
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEIDENTIFY_SA_EMAIL}" \
    --role="roles/storage.objectViewer" \
    --condition=None

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEIDENTIFY_SA_EMAIL}" \
    --role="roles/bigquery.dataViewer" \
    --condition=None

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEIDENTIFY_SA_EMAIL}" \
    --role="roles/dlp.reader" \
    --condition=None

# Permissions in research project
gcloud projects add-iam-policy-binding "$RESEARCH_PROJECT_ID" \
    --member="serviceAccount:${DEIDENTIFY_SA_EMAIL}" \
    --role="roles/storage.objectCreator" \
    --condition=None

gcloud projects add-iam-policy-binding "$RESEARCH_PROJECT_ID" \
    --member="serviceAccount:${DEIDENTIFY_SA_EMAIL}" \
    --role="roles/bigquery.dataEditor" \
    --condition=None

# Configure perimeter bridge
print_info "Configuring VPC Service Controls perimeter bridge..."

# Create bridge configuration
cat > /tmp/perimeter_bridge.yaml <<EOF
bridges:
- resources:
  - projects/${PROJECT_NUMBER}
  - projects/${RESEARCH_PROJECT_NUMBER}
  perimeters:
  - accessPolicies/${ACCESS_POLICY_NAME}/servicePerimeters/${PERIMETER_NAME}
  - accessPolicies/${ACCESS_POLICY_NAME}/servicePerimeters/${RESEARCH_PERIMETER_NAME}
EOF

# Update perimeters to create bridge
print_info "Creating perimeter bridge between primary and research perimeters..."

# Note: This is a simplified approach. In production, use proper perimeter update
print_warning "MANUAL STEP REQUIRED: Configure perimeter bridge"
print_warning "============================================="
echo ""
echo "To create the perimeter bridge:"
echo "1. Go to VPC Service Controls in Console"
echo "2. Edit both perimeters to include bridge configuration"
echo "3. Add the following to both perimeters:"
echo "   - Bridge projects: $PROJECT_NUMBER, $RESEARCH_PROJECT_NUMBER"
echo "   - Restricted services: storage.googleapis.com, bigquery.googleapis.com"
echo ""
echo "This allows controlled data flow from primary to research perimeter"
echo ""
read -p "Press ENTER when perimeter bridge is configured..."

# Create egress rule for cross-perimeter transfers
print_info "Creating egress rule for BigQuery transfers..."

cat > /tmp/bigquery_transfer_egress.yaml <<EOF
egressPolicies:
- egressFrom:
    identities:
    - serviceAccount:${DEIDENTIFY_SA_EMAIL}
  egressTo:
    operations:
    - serviceName: storage.googleapis.com
      methodSelectors:
      - method: "google.storage.objects.create"
    - serviceName: bigquery.googleapis.com
      methodSelectors:
      - method: "google.cloud.bigquery.v2.TableService.InsertAll"
      - method: "google.cloud.bigquery.v2.TableService.Get"
    resources:
    - projects/${RESEARCH_PROJECT_NUMBER}
EOF

print_info "Egress rule configuration saved to /tmp/bigquery_transfer_egress.yaml"
echo "Apply this to the primary perimeter to allow data export to research"

# Create data flow documentation
cat > /tmp/data_flow_architecture.md <<EOF
# ${ORGANIZATION_NAME} Health Sciences Data Flow Architecture

## Overview
Secure data flow from raw PHI to de-identified research data using BigQuery and DLP.

## Architecture Components

### Primary Perimeter (${PERIMETER_NAME})
- Contains: Raw PHI/PII data
- Project: ${PROJECT_ID}
- Restrictions: Highly restricted access

### Research Perimeter (${RESEARCH_PERIMETER_NAME})
- Contains: De-identified data only
- Project: ${RESEARCH_PROJECT_ID}
- Access: Broader researcher access

### Perimeter Bridge
- Connects: Primary ↔ Research
- Service Account: ${DEIDENTIFY_SA_EMAIL}
- Allowed Operations:
  - Read from primary BigQuery/Storage
  - Write to research BigQuery/Storage
  - Use DLP for scanning and classification

## Data Flow Process

1. Raw Data Landing
   - Location: BigQuery dataset in ${PROJECT_ID}
   - Format: Original PHI data

2. DLP Scanning
   - Manual or scheduled scans
   - Identifies PHI columns
   - Results stored for reference

3. De-identified Transfer
   - Manual process using BigQuery views
   - Apply transformations based on DLP findings
   - Transfer to research project

4. Research Access
   - Location: ${RESEARCH_PROJECT_ID}:healthcare_research
   - Format: De-identified, HIPAA-compliant views

## Security Controls

- VPC Service Controls prevent unauthorized data movement
- Only authorized service accounts can bridge perimeters
- All operations are logged and audited
- De-identification is based on DLP findings
EOF

print_info "Data flow architecture saved to /tmp/data_flow_architecture.md"

# Update state
save_state "PERIMETER_BRIDGE_CONFIGURED" "true"
save_state "DEIDENTIFY_SA_EMAIL" "$DEIDENTIFY_SA_EMAIL"
save_state "BRIDGE_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Perimeter bridge configuration completed!"
echo ""
echo "Bridge Details:"
echo "- Primary perimeter: $PERIMETER_NAME"
echo "- Research perimeter: $RESEARCH_PERIMETER_NAME"
echo "- Transfer service account: $DEIDENTIFY_SA_EMAIL"
echo "- Allowed flow: Primary → Research (one-way)"
echo ""
echo "Next step: ./setup-bigquery-dlp-infrastructure.sh"
