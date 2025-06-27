#!/bin/bash
# Set up Customer-Managed Encryption Keys (CMEK) for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Setting up Customer-Managed Encryption Keys"
echo "===================================="
echo ""

# Check prerequisites
if [ "$PHASE_04_COMPLETE" != "true" ]; then
    print_error "Phase 04 not complete. Please complete logging & monitoring setup first."
    exit 1
fi

# Set project context
gcloud config set project "$PROJECT_ID"

# Create KMS keyring
print_info "Creating KMS keyring: $KMS_KEYRING_NAME"

if gcloud kms keyrings describe "$KMS_KEYRING_NAME" \
    --location="$REGION" &>/dev/null 2>&1; then
    print_warning "KMS keyring already exists: $KMS_KEYRING_NAME"
else
    if gcloud kms keyrings create "$KMS_KEYRING_NAME" \
        --location="$REGION"; then
        print_success "Created KMS keyring: $KMS_KEYRING_NAME"
    else
        print_error "Failed to create KMS keyring"
        exit 1
    fi
fi

# Function to create KMS key
create_kms_key() {
    local KEY_NAME=$1
    local PURPOSE=$2
    local ROTATION_PERIOD=$3
    local DESCRIPTION=$4
    
    print_info "Creating KMS key: $KEY_NAME"
    
    # Check if key already exists
    if gcloud kms keys describe "$KEY_NAME" \
        --keyring="$KMS_KEYRING_NAME" \
        --location="$REGION" &>/dev/null 2>&1; then
        print_warning "KMS key already exists: $KEY_NAME"
        return 0
    fi
    
    # Create key
    if gcloud kms keys create "$KEY_NAME" \
        --keyring="$KMS_KEYRING_NAME" \
        --location="$REGION" \
        --purpose="$PURPOSE" \
        --rotation-period="$ROTATION_PERIOD" \
        --next-rotation-time="+30d" \
        --labels="environment=production,compliance=hipaa-fedramp" \
        --protection-level="software"; then
        print_success "Created KMS key: $KEY_NAME"
        
        # Add description (requires update)
        gcloud kms keys update "$KEY_NAME" \
            --keyring="$KMS_KEYRING_NAME" \
            --location="$REGION" \
            --update-labels="description=$DESCRIPTION"
        
        return 0
    else
        print_error "Failed to create KMS key: $KEY_NAME"
        return 1
    fi
}

# Create encryption keys
create_kms_key \
    "$STORAGE_KEY_NAME" \
    "encryption" \
    "90d" \
    "CMEK for Cloud Storage buckets containing PHI/PII"

create_kms_key \
    "$KMS_KEY_DATABASE" \
    "encryption" \
    "90d" \
    "CMEK for database encryption (Cloud SQL, BigQuery)"

create_kms_key \
    "$COMPUTE_KEY_NAME" \
    "encryption" \
    "90d" \
    "CMEK for compute disk encryption"

# Create BigQuery-specific key
create_kms_key \
    "$BIGQUERY_KEY_NAME" \
    "encryption" \
    "90d" \
    "CMEK for BigQuery datasets"

# Grant service accounts access to keys
print_info "Granting service accounts access to encryption keys..."

# Get project number
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# Grant Compute Engine service account access
COMPUTE_SA="service-${PROJECT_NUMBER}@compute-system.iam.gserviceaccount.com"
if gcloud kms keys add-iam-policy-binding "$COMPUTE_KEY_NAME" \
    --keyring="$KMS_KEYRING_NAME" \
    --location="$REGION" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"; then
    print_success "Granted Compute Engine access to encryption key"
else
    print_warning "Failed to grant Compute Engine access"
fi

# Grant Cloud Storage service account access
STORAGE_SA="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"
if gcloud kms keys add-iam-policy-binding "$STORAGE_KEY_NAME" \
    --keyring="$KMS_KEYRING_NAME" \
    --location="$REGION" \
    --member="serviceAccount:${STORAGE_SA}" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"; then
    print_success "Granted Cloud Storage access to encryption key"
else
    print_warning "Failed to grant Cloud Storage access"
fi

# Grant BigQuery service account access
BQ_SA="bq-${PROJECT_NUMBER}@bigquery-encryption.iam.gserviceaccount.com"
if gcloud kms keys add-iam-policy-binding "$BIGQUERY_KEY_NAME" \
    --keyring="$KMS_KEYRING_NAME" \
    --location="$REGION" \
    --member="serviceAccount:${BQ_SA}" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"; then
    print_success "Granted BigQuery access to encryption key"
else
    print_warning "Failed to grant BigQuery access"
fi

# Display key information
print_info "KMS Key Configuration:"
echo "====================="
gcloud kms keys list \
    --keyring="$KMS_KEYRING_NAME" \
    --location="$REGION" \
    --format="table(name.basename(),purpose,rotationPeriod,labels)"

# Create key usage policy
print_info "Creating key usage policy..."

cat > /tmp/key_usage_policy.yaml <<EOF
# KMS Key Usage Policy for ${ORGANIZATION_NAME} Health Sciences

## Storage Key (${STORAGE_KEY_NAME})
- Used for: All Cloud Storage buckets containing PHI/PII
- Rotation: Every 90 days
- Access: Storage service account only

## Database Key (${KMS_KEY_DATABASE})
- Used for: Cloud SQL instances and other databases
- Rotation: Every 90 days
- Access: Database service accounts only

## BigQuery Key (${BIGQUERY_KEY_NAME})
- Used for: BigQuery datasets containing PHI/PII
- Rotation: Every 90 days
- Access: BigQuery service account only

## Compute Key (${COMPUTE_KEY_NAME})
- Used for: VM disk encryption
- Rotation: Every 90 days
- Access: Compute Engine service account only

## Key Management Procedures
1. Keys rotate automatically per schedule
2. Old key versions remain for decryption only
3. Key destruction requires approval process
4. All key usage is logged and audited
EOF

print_info "Key usage policy saved to /tmp/key_usage_policy.yaml"

# Update state
save_state "CMEK_CONFIGURED" "true"
save_state "KMS_KEYRING_NAME" "$KMS_KEYRING_NAME"
save_state "CMEK_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Customer-Managed Encryption Keys configured!"
echo ""
echo "Summary:"
echo "- Keyring: $KMS_KEYRING_NAME"
echo "- Storage key: $STORAGE_KEY_NAME (90-day rotation)"
echo "- Database key: $KMS_KEY_DATABASE (90-day rotation)"
echo "- BigQuery key: $BIGQUERY_KEY_NAME (90-day rotation)"
echo "- Compute key: $COMPUTE_KEY_NAME (90-day rotation)"
echo ""
echo "Next step: ./configure-storage-encryption.sh"
