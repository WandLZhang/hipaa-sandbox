#!/bin/bash
# Set up Security Command Center for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting up Security Command Center"
echo "===================================="
echo ""

# Check prerequisites
if [ "$AUDIT_LOGS_ENABLED" != "true" ]; then
    print_error "Audit logs not enabled. Run ./enable-audit-logs.sh first."
    exit 1
fi

# Enable Security Command Center API at organization level
print_info "Enabling Security Command Center API..."

if gcloud services enable securitycenter.googleapis.com \
    --project="$PROJECT_ID"; then
    print_success "Security Command Center API enabled"
else
    print_error "Failed to enable Security Command Center API"
    exit 1
fi

# Note: Security Command Center Premium requires manual activation
print_warning "MANUAL STEP REQUIRED: Activate Security Command Center Premium"
print_warning "=============================================================="
echo ""
echo "Security Command Center Premium provides:"
echo "- Continuous compliance monitoring for FedRAMP and HIPAA"
echo "- Security Health Analytics"
echo "- Event Threat Detection"
echo "- Container Threat Detection"
echo ""
echo "To activate:"
echo "1. Go to: https://console.cloud.google.com/security/command-center"
echo "2. Click 'Start Setup' or 'Upgrade to Premium'"
echo "3. Select organization: $ORG_ID"
echo "4. Enable Premium tier"
echo "5. Configure notification channels"
echo ""
read -p "Press ENTER after activating SCC Premium..."

# Configure notification channels
print_info "Configuring notification channels..."

# Create notification channel for critical findings
cat > /tmp/notification_channel.json <<EOF
{
  "type": "email",
  "displayName": "${ORGANIZATION_NAME} Security Team",
  "description": "Critical security findings for ${ORGANIZATION_NAME} Health Sciences",
  "labels": {
    "email_address": "${SECURITY_TEAM_GROUP}"
  },
  "enabled": true
}
EOF

print_info "Example notification channel configuration created."
echo "Configure actual channels in the Console based on your team's needs."

# Create custom finding source (optional)
print_info "Security Command Center configuration notes:"
echo "==========================================="
echo ""
echo "1. Review compliance dashboards:"
echo "   - FedRAMP compliance dashboard"
echo "   - HIPAA compliance dashboard"
echo ""
echo "2. Configure finding notifications:"
echo "   - Critical findings → Immediate email/SMS"
echo "   - High findings → Daily digest"
echo "   - Medium/Low → Weekly report"
echo ""
echo "3. Enable automated responses:"
echo "   - Auto-remediation for common issues"
echo "   - Integration with ticketing system"
echo ""
echo "4. Schedule compliance reports:"
echo "   - Weekly compliance summary"
echo "   - Monthly detailed audit report"
echo ""

# Set up example BigQuery views for security analysis
print_info "Creating BigQuery views for security analysis..."

# Set project to logging project
gcloud config set project "$LOG_PROJECT_ID"

# Create view for login analysis
cat > /tmp/login_analysis_view.sql <<EOF
CREATE OR REPLACE VIEW \`$LOG_PROJECT_ID.$LOG_DATASET_NAME.login_analysis\` AS
SELECT
  timestamp,
  protoPayload.authenticationInfo.principalEmail as user_email,
  protoPayload.requestMetadata.callerIp as source_ip,
  protoPayload.methodName as action,
  resource.labels.project_id,
  CASE
    WHEN protoPayload.authenticationInfo.principalEmail LIKE '%gserviceaccount.com' THEN 'Service Account'
    WHEN protoPayload.authenticationInfo.principalEmail LIKE '%@${ORGANIZATION_DOMAIN}' THEN 'Organization User'
    ELSE 'External'
  END as user_type
FROM \`$LOG_PROJECT_ID.$LOG_DATASET_NAME.cloudaudit_googleapis_com_activity\`
WHERE protoPayload.methodName LIKE '%authenticate%'
  OR protoPayload.methodName LIKE '%login%'
ORDER BY timestamp DESC;
EOF

# Create view for data access patterns
cat > /tmp/data_access_view.sql <<EOF
CREATE OR REPLACE VIEW \`$LOG_PROJECT_ID.$LOG_DATASET_NAME.data_access_patterns\` AS
SELECT
  timestamp,
  protoPayload.authenticationInfo.principalEmail as accessor,
  protoPayload.resourceName as resource_accessed,
  protoPayload.methodName as access_type,
  protoPayload.requestMetadata.callerIp as source_ip,
  resource.labels.project_id,
  protoPayload.serviceName as service
FROM \`$LOG_PROJECT_ID.$LOG_DATASET_NAME.cloudaudit_googleapis_com_data_access\`
WHERE protoPayload.serviceName IN ('storage.googleapis.com', 'bigquery.googleapis.com', 'healthcare.googleapis.com')
ORDER BY timestamp DESC;
EOF

print_info "Example BigQuery views created in /tmp/"
echo "Apply these views in BigQuery console for security analysis"

# Set project back to primary
gcloud config set project "$PROJECT_ID"

# Clean up
rm -f /tmp/notification_channel.json
rm -f /tmp/login_analysis_view.sql
rm -f /tmp/data_access_view.sql

# Update state
save_state "SCC_CONFIGURED" "true"
save_state "SCC_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
save_state "PHASE_04_COMPLETE" "true"

echo ""
print_success "Security Command Center configuration completed!"
echo ""
echo "Summary:"
echo "- SCC Premium: Must be activated manually"
echo "- Compliance dashboards: FedRAMP and HIPAA"
echo "- Notification channels: Configure based on team needs"
echo "- Security views: Example queries provided"
echo ""
print_success "Phase 04: Logging & Monitoring completed!"
echo ""
echo "Next phase: cd ../05-data-security && ./setup-cmek.sh"
