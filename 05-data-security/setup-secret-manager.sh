#!/bin/bash
# Set up Secret Manager for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting up Secret Manager"
echo "===================================="
echo ""

# Check prerequisites
if [ "$DLP_CONFIGURED" != "true" ]; then
    print_error "DLP not configured. Run ./setup-dlp.sh first."
    exit 1
fi

# Set project context
gcloud config set project "$PROJECT_ID"

# Enable Secret Manager API
print_info "Enabling Secret Manager API..."

if gcloud services enable secretmanager.googleapis.com; then
    print_success "Secret Manager API enabled"
else
    print_error "Failed to enable Secret Manager API"
    exit 1
fi

# Function to create secret
create_secret() {
    local SECRET_NAME=$1
    local SECRET_DESCRIPTION=$2
    local REPLICATION_POLICY=$3
    
    print_info "Creating secret: $SECRET_NAME"
    
    # Check if secret already exists
    if gcloud secrets describe "$SECRET_NAME" &>/dev/null 2>&1; then
        print_warning "Secret already exists: $SECRET_NAME"
        return 0
    fi
    
    # Create secret with automatic replication
    if [ "$REPLICATION_POLICY" = "automatic" ]; then
        if gcloud secrets create "$SECRET_NAME" \
            --replication-policy="automatic" \
            --labels="environment=production,compliance=hipaa-fedramp" \
            --data-file=- <<< "placeholder-value"; then
            print_success "Created secret: $SECRET_NAME"
        else
            print_error "Failed to create secret: $SECRET_NAME"
            return 1
        fi
    else
        # Create with user-managed replication for compliance
        if gcloud secrets create "$SECRET_NAME" \
            --replication-policy="user-managed" \
            --replica-locations="$REGION" \
            --labels="environment=production,compliance=hipaa-fedramp" \
            --data-file=- <<< "placeholder-value"; then
            print_success "Created secret: $SECRET_NAME (regional replication)"
        else
            print_error "Failed to create secret: $SECRET_NAME"
            return 1
        fi
    fi
    
    # Add description
    gcloud secrets update "$SECRET_NAME" \
        --update-labels="description=$SECRET_DESCRIPTION"
    
    return 0
}

# Create database secrets
create_secret \
    "db-master-password" \
    "Master password for Cloud SQL instances" \
    "user-managed"

create_secret \
    "db-app-password" \
    "Application database password" \
    "user-managed"

# Create API keys secret
create_secret \
    "api-keys" \
    "External API keys for integrations" \
    "user-managed"

# Create encryption secrets
create_secret \
    "app-encryption-key" \
    "Application-layer encryption key" \
    "user-managed"

create_secret \
    "jwt-signing-key" \
    "JWT token signing key" \
    "user-managed"

# Create service account keys secret
create_secret \
    "sa-keys" \
    "Service account keys for external services" \
    "user-managed"

# Create VPN shared secret (already exists in environment)
print_info "Storing VPN shared secret..."

SECRET_NAME="vpn-shared-secret"
if gcloud secrets describe "$SECRET_NAME" &>/dev/null 2>&1; then
    print_warning "VPN secret already exists"
else
    # Create secret from environment variable
    echo -n "$SHARED_SECRET" | gcloud secrets create "$SECRET_NAME" \
        --replication-policy="user-managed" \
        --replica-locations="$REGION" \
        --labels="environment=production,compliance=hipaa-fedramp,description=VPN-shared-secret-for-on-premises-connection" \
        --data-file=-
    
    if [ $? -eq 0 ]; then
        print_success "Created VPN shared secret"
    else
        print_error "Failed to create VPN shared secret"
    fi
fi

# Set up secret access permissions
print_info "Configuring secret access permissions..."

# Create a service account for secret access
SA_NAME="secret-accessor"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null 2>&1; then
    print_warning "Service account already exists: $SA_NAME"
else
    if gcloud iam service-accounts create "$SA_NAME" \
        --display-name="Secret Manager Access Account" \
        --description="Service account for accessing secrets in production"; then
        print_success "Created service account: $SA_NAME"
    else
        print_error "Failed to create service account"
    fi
fi

# Grant secret accessor role to the service account
print_info "Granting secret accessor permissions..."

for SECRET in "db-master-password" "db-app-password" "api-keys" "app-encryption-key" "jwt-signing-key"; do
    if gcloud secrets add-iam-policy-binding "$SECRET" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/secretmanager.secretAccessor"; then
        check_status "Granted access to $SECRET"
    else
        check_status "Failed to grant access to $SECRET"
    fi
done

# Create secret rotation schedule
print_info "Setting up secret rotation reminders..."

cat > /tmp/secret_rotation_policy.yaml <<EOF
# Secret Rotation Policy for ${ORGANIZATION_NAME} Health Sciences

## Rotation Schedule

### High Priority (30 days)
- db-master-password
- db-app-password
- jwt-signing-key

### Medium Priority (90 days)
- api-keys
- app-encryption-key

### Low Priority (180 days)
- sa-keys
- vpn-shared-secret

## Rotation Process

1. Generate new secret value
2. Update secret version in Secret Manager
3. Update application configuration
4. Verify new secret works
5. Disable old secret version
6. After 7 days, destroy old version

## Automated Rotation

To enable automated rotation:
1. Create Cloud Scheduler job
2. Trigger Cloud Function
3. Function generates new secret
4. Updates Secret Manager
5. Notifies operations team

## Access Logging

All secret access is logged to:
- Cloud Audit Logs
- BigQuery dataset: ${LOG_PROJECT_ID}:${LOG_DATASET_NAME}
EOF

print_info "Secret rotation policy saved to /tmp/secret_rotation_policy.yaml"

# Display secret configuration
print_info "Secret Manager configuration:"
echo "============================"

gcloud secrets list \
    --format="table(name.basename(),replication.userManaged.replicas[0].location,labels.description)"

# Create example for accessing secrets in code
cat > /tmp/secret_access_example.py <<EOF
#!/usr/bin/env python3
"""
Example: Accessing secrets from Secret Manager in Python
"""

from google.cloud import secretmanager

def access_secret(project_id, secret_id, version_id="latest"):
    """Access a secret from Secret Manager"""
    
    # Create the Secret Manager client
    client = secretmanager.SecretManagerServiceClient()
    
    # Build the secret version name
    name = f"projects/{project_id}/secrets/{secret_id}/versions/{version_id}"
    
    # Access the secret
    response = client.access_secret_version(request={"name": name})
    
    # Return the decoded payload
    return response.payload.data.decode('UTF-8')

# Example usage
if __name__ == "__main__":
    project_id = "${PROJECT_ID}"
    
    # Access database password
    db_password = access_secret(project_id, "db-master-password")
    print(f"Retrieved database password: {'*' * len(db_password)}")
    
    # Access API key
    api_key = access_secret(project_id, "api-keys")
    print(f"Retrieved API key: {api_key[:4]}...{api_key[-4:]}")
EOF

print_info "Secret access example saved to /tmp/secret_access_example.py"

# Update state
save_state "SECRET_MANAGER_CONFIGURED" "true"
save_state "SECRET_ACCESSOR_SA" "$SA_EMAIL"
save_state "SECRET_MANAGER_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
save_state "PHASE_05_COMPLETE" "true"

echo ""
print_success "Secret Manager configured successfully!"
echo ""
echo "Secrets created:"
echo "- Database passwords (regional replication)"
echo "- API keys (regional replication)"
echo "- Encryption keys (regional replication)"
echo "- VPN shared secret (imported from config)"
echo ""
echo "Access control:"
echo "- Service account: $SA_EMAIL"
echo "- All access is logged and audited"
echo ""
print_success "Phase 05: Data Security completed!"
echo ""
echo "Next phase: cd ../06-data-pipeline && ./setup-perimeter-bridge.sh"
