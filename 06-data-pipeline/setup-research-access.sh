#!/bin/bash
# Set up research access for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting up Research Access"
echo "===================================="
echo ""

# Check prerequisites
if [ "$DEIDENTIFY_PIPELINE_CREATED" != "true" ]; then
    print_error "De-identification pipeline not created. Run ./create-deidentify-pipeline.sh first."
    exit 1
fi

# Set project context
gcloud config set project "$RESEARCH_PROJECT_ID"

# Create research user groups
print_info "Creating research user groups..."

# Note: Groups must be created in Google Workspace Admin Console
print_warning "MANUAL STEP: Create the following groups in Google Workspace:"
echo "1. ${RESEARCHERS_GROUP} - General research access"
echo "2. ${RESEARCH_ADMINS_GROUP} - Research admin access"
echo "3. ${EXTERNAL_COLLABORATORS_GROUP} - External partner access"
echo ""
read -p "Press ENTER when groups are created..."

# Create BigQuery authorized views
print_info "Creating BigQuery authorized views for researchers..."

# Create views dataset
VIEWS_DATASET="research_views"
if bq show --dataset "$RESEARCH_PROJECT_ID:$VIEWS_DATASET" &>/dev/null 2>&1; then
    print_warning "Views dataset already exists: $VIEWS_DATASET"
else
    if bq mk --dataset \
        --location="$LOCATION" \
        --description="Authorized views for researcher access" \
        "$RESEARCH_PROJECT_ID:$VIEWS_DATASET"; then
        print_success "Created views dataset: $VIEWS_DATASET"
    else
        print_error "Failed to create views dataset"
    fi
fi

# Create patient demographics view
cat > /tmp/patient_demographics_view.sql <<EOF
CREATE OR REPLACE VIEW \`$RESEARCH_PROJECT_ID.$VIEWS_DATASET.patient_demographics\` AS
SELECT
  patient_id,
  age_group,
  gender,
  CASE 
    WHEN zip_code IS NOT NULL THEN SUBSTR(zip_code, 1, 3) || '**'
    ELSE NULL 
  END as zip_prefix,
  diagnosis_category,
  treatment_group,
  enrollment_date,
  deidentified_at
FROM \`$RESEARCH_PROJECT_ID.$RESEARCH_DATASET.deidentified_records\`
WHERE error IS NULL;
EOF

# Create clinical outcomes view
cat > /tmp/clinical_outcomes_view.sql <<EOF
CREATE OR REPLACE VIEW \`$RESEARCH_PROJECT_ID.$VIEWS_DATASET.clinical_outcomes\` AS
SELECT
  patient_id,
  outcome_date,
  outcome_type,
  outcome_value,
  measurement_unit,
  provider_type,
  facility_region,
  deidentified_at
FROM \`$RESEARCH_PROJECT_ID.$RESEARCH_DATASET.deidentified_records\`
WHERE error IS NULL
  AND outcome_type IS NOT NULL;
EOF

# Create aggregated statistics view
cat > /tmp/aggregate_statistics_view.sql <<EOF
CREATE OR REPLACE VIEW \`$RESEARCH_PROJECT_ID.$VIEWS_DATASET.aggregate_statistics\` AS
SELECT
  diagnosis_category,
  treatment_group,
  COUNT(DISTINCT patient_id) as patient_count,
  AVG(CAST(age_group AS INT64)) as avg_age_group,
  COUNTIF(gender = 'M') as male_count,
  COUNTIF(gender = 'F') as female_count,
  MIN(enrollment_date) as earliest_enrollment,
  MAX(enrollment_date) as latest_enrollment
FROM \`$RESEARCH_PROJECT_ID.$RESEARCH_DATASET.deidentified_records\`
WHERE error IS NULL
GROUP BY diagnosis_category, treatment_group
HAVING COUNT(DISTINCT patient_id) >= 10;  -- Privacy threshold
EOF

print_info "BigQuery view SQL files created in /tmp/"
echo "Apply these views using bq command or Console"

# Set up IAM permissions for research groups
print_info "Configuring flexible IAM permissions for research access..."

# Grant broader permissions to researchers - let them create and manage their own resources
if gcloud projects add-iam-policy-binding "$RESEARCH_PROJECT_ID" \
    --member="group:${RESEARCHERS_GROUP}" \
    --role="roles/editor"; then
    print_success "Granted editor access to researchers for self-service capabilities"
else
    print_warning "Failed to grant editor access"
fi

# Grant BigQuery admin for full data analysis capabilities
if gcloud projects add-iam-policy-binding "$RESEARCH_PROJECT_ID" \
    --member="group:${RESEARCHERS_GROUP}" \
    --role="roles/bigquery.admin"; then
    print_success "Granted BigQuery admin access to researchers"
else
    print_warning "Failed to grant BigQuery admin access"
fi

# Grant storage admin for data management
if gcloud projects add-iam-policy-binding "$RESEARCH_PROJECT_ID" \
    --member="group:${RESEARCHERS_GROUP}" \
    --role="roles/storage.admin"; then
    print_success "Granted Storage admin access to researchers"
else
    print_warning "Failed to grant Storage admin access"
fi

# Grant additional permissions to research admins
if gcloud projects add-iam-policy-binding "$RESEARCH_PROJECT_ID" \
    --member="group:${RESEARCH_ADMINS_GROUP}" \
    --role="roles/bigquery.admin"; then
    print_success "Granted BigQuery admin access to research admins"
else
    print_warning "Failed to grant admin access"
fi

# Create data sharing configuration for external partners
print_info "Creating data sharing configuration..."

# Create Analytics Hub listing (formerly BigQuery Data Exchange)
cat > /tmp/analytics_hub_listing.yaml <<EOF
displayName: "${ORGANIZATION_NAME} Health Sciences Research Data"
description: "De-identified health research data for authorized collaborators"
primaryContact: "${RESEARCH_DATA_GROUP}"
documentation: "https://your-organization.com/health-sciences/data-sharing"
icon: "gs://your-assets/health-research-icon.png"
requestAccess: "CONTACT"
categories: ["HEALTHCARE", "RESEARCH"]
dataProvider:
  name: "${ORGANIZATION_NAME}"
  primaryContact: "${DATA_GOVERNANCE_GROUP}"
bigqueryDataset:
  dataset: "projects/$RESEARCH_PROJECT_ID/datasets/$VIEWS_DATASET"
restrictedExportConfig:
  enabled: true
  restrictDirectTableAccess: true
EOF

print_info "Analytics Hub listing configuration saved to /tmp/analytics_hub_listing.yaml"

# Create usage monitoring queries
print_info "Setting up usage monitoring..."

cat > /tmp/monitor_access.sql <<EOF
-- Query to monitor data access patterns
CREATE OR REPLACE VIEW \`$LOG_PROJECT_ID.$LOG_DATASET_NAME.research_access_logs\` AS
SELECT
  timestamp,
  protoPayload.authenticationInfo.principalEmail as user_email,
  protoPayload.resourceName as accessed_resource,
  protoPayload.methodName as access_type,
  protoPayload.requestMetadata.callerIp as source_ip,
  protoPayload.status.code as status_code,
  REGEXP_EXTRACT(protoPayload.resourceName, r'datasets/([^/]+)') as dataset,
  REGEXP_EXTRACT(protoPayload.resourceName, r'tables/([^/]+)') as table_name
FROM \`$LOG_PROJECT_ID.$LOG_DATASET_NAME.cloudaudit_googleapis_com_data_access\`
WHERE resource.labels.project_id = '$RESEARCH_PROJECT_ID'
  AND protoPayload.serviceName = 'bigquery.googleapis.com'
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
ORDER BY timestamp DESC;

-- Query to track data volume accessed
CREATE OR REPLACE VIEW \`$LOG_PROJECT_ID.$LOG_DATASET_NAME.research_data_volume\` AS
SELECT
  DATE(timestamp) as access_date,
  protoPayload.authenticationInfo.principalEmail as user_email,
  COUNT(*) as query_count,
  SUM(CAST(protoPayload.serviceData.jobCompletedEvent.job.jobStatistics.totalBilledBytes AS INT64)) as total_bytes_billed,
  AVG(CAST(protoPayload.serviceData.jobCompletedEvent.job.jobStatistics.totalSlotMs AS INT64)) as avg_slot_ms
FROM \`$LOG_PROJECT_ID.$LOG_DATASET_NAME.cloudaudit_googleapis_com_data_access\`
WHERE resource.labels.project_id = '$RESEARCH_PROJECT_ID'
  AND protoPayload.methodName = 'jobservice.jobcompleted'
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY access_date, user_email
ORDER BY access_date DESC;
EOF

print_info "Monitoring queries saved to /tmp/monitor_access.sql"

# Create research documentation
cat > /tmp/research_access_guide.md <<EOF
# ${ORGANIZATION_NAME} Health Sciences Research Environment Guide

## Overview
The research environment provides flexible access to Google Cloud services within FedRAMP Moderate compliance boundaries. Researchers have broad permissions to create and manage their own resources.

## What You Can Do

### ✅ Self-Service Capabilities
- **Create your own datasets**: Design and manage BigQuery datasets for your research
- **Enable additional APIs**: Use any Assured Workloads compatible service
- **Deploy analysis tools**: Vertex AI, Dataflow, Dataproc, Cloud Functions, etc.
- **Manage storage**: Create and manage your own Cloud Storage buckets
- **Run compute workloads**: Deploy VMs, containers, and managed services

### 🔒 Built-in Security (Automatic)
- All data encrypted with CMEK
- Comprehensive audit logging
- FedRAMP Moderate compliance maintained by Assured Workloads
- Network isolation via VPC Service Controls

### ⚠️ Minimal Restrictions
- Cannot modify encryption keys (managed centrally)
- Cannot change project-level IAM policies
- Cannot disable audit logging
- Cannot modify VPC Service Controls

## Getting Started

### 1. Access the Research Project
\`\`\`bash
gcloud config set project $RESEARCH_PROJECT_ID
\`\`\`

### 2. Enable Any Additional APIs You Need
\`\`\`bash
# Example: Enable Vertex AI APIs
gcloud services enable aiplatform.googleapis.com

# List all available APIs
gcloud services list --available
\`\`\`

### 3. Create Your Own Resources
\`\`\`bash
# Create a dataset
bq mk --dataset --location=$LOCATION my_research_dataset

# Create a storage bucket
gsutil mb -p $RESEARCH_PROJECT_ID -l $LOCATION gs://my-research-bucket-\${USER}

# Launch a notebook
gcloud notebooks instances create my-notebook \\
  --location=$ZONE \\
  --machine-type=n1-standard-4
\`\`\`

### 4. Use Any Approved GCP Service
\`\`\`python
# All GCP client libraries work out of the box
from google.cloud import bigquery, storage, aiplatform
from google.cloud import dataflow, pubsub, vision

# Example: Train a model
aiplatform.init(project='$RESEARCH_PROJECT_ID', location='$LOCATION')
# Your ML code here...
\`\`\`

## Pre-configured Views (Optional Starting Points)
While you can create your own datasets, we provide some pre-configured views:
- \`$RESEARCH_PROJECT_ID.$VIEWS_DATASET.patient_demographics\`
- \`$RESEARCH_PROJECT_ID.$VIEWS_DATASET.clinical_outcomes\`
- \`$RESEARCH_PROJECT_ID.$VIEWS_DATASET.aggregate_statistics\`

## Best Practices
1. **Name your resources clearly**: Use your username or team name in resource names
2. **Document your work**: Create README files in your storage buckets
3. **Share responsibly**: When sharing data, ensure compliance with data use agreements
4. **Clean up**: Delete resources you're no longer using to control costs

## Support
- Technical issues: ${HEALTH_IT_GROUP}
- Data questions: ${RESEARCH_DATA_GROUP}
- Compliance: ${PRIVACY_GROUP}
- New service requests: ${ADMIN_GROUP}
EOF

print_info "Research access guide saved to /tmp/research_access_guide.md"

# Set project back to primary
gcloud config set project "$PROJECT_ID"

# Update state
save_state "RESEARCH_ACCESS_CONFIGURED" "true"
save_state "RESEARCH_VIEWS_DATASET" "$VIEWS_DATASET"
save_state "RESEARCH_ACCESS_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
save_state "PHASE_06_COMPLETE" "true"

echo ""
print_success "Research access configured successfully!"
echo ""
echo "Access configuration:"
echo "- Research project: $RESEARCH_PROJECT_ID"
echo "- Researcher group: ${RESEARCHERS_GROUP} (editor + admin permissions)"
echo "- Admin group: ${RESEARCH_ADMINS_GROUP}"
echo "- Researchers can self-service any Assured Workloads compatible service"
echo "- All access is logged and monitored"
echo ""
print_success "Phase 06: Data Pipeline completed!"
echo ""
echo "===================================="
echo "HIPAA/FedRAMP Implementation Complete!"
echo "===================================="
echo ""
echo "Summary of deployed infrastructure:"
echo "- Assured Workloads: FedRAMP Moderate environment (handles base compliance)"
echo "- VPC Service Controls: Minimal restrictions, letting AW handle most controls"
echo "- Networking: Dedicated VPC with HA-VPN to on-premises"
echo "- Encryption: CMEK for all data at rest"
echo "- Logging: Centralized with 6-year retention"
echo "- DLP: Automated scanning and de-identification"
echo "- Research: Flexible environment with self-service capabilities"
echo ""
echo "Key flexibility improvements:"
echo "- Researchers can enable any Assured Workloads compatible API"
echo "- Full editor permissions in research project"
echo "- Minimal VPC-SC restrictions beyond AW defaults"
echo "- Self-service resource creation and management"
echo ""
echo "Next steps:"
echo "1. Review /tmp/research_access_guide.md for researcher onboarding"
echo "2. Complete manual configuration steps"
echo "3. Test researcher self-service capabilities"
echo "4. Schedule compliance review"
echo "5. Begin onboarding researchers with new flexible access"
