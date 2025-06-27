#!/bin/bash
# Configure Cloud Storage encryption with CMEK for HIPAA/FedRAMP implementation

# Load environment and state
source ../config/environment.conf
load_state

echo "===================================="
echo "Configuring Storage Encryption"
echo "===================================="
echo ""

# Check prerequisites
if [ "$CMEK_CONFIGURED" != "true" ]; then
    print_error "CMEK not configured. Run ./setup-cmek.sh first."
    exit 1
fi

# Set project context
gcloud config set project "$PROJECT_ID"

# Function to create encrypted bucket
create_encrypted_bucket() {
    local BUCKET_NAME=$1
    local BUCKET_PURPOSE=$2
    local SUGGESTED_RETENTION=$3
    local BUCKET_DESCRIPTION=$4
    
    print_info "Creating encrypted bucket: $BUCKET_NAME"
    
    # Check if bucket already exists
    if gsutil ls -b "gs://$BUCKET_NAME" &>/dev/null 2>&1; then
        print_warning "Bucket already exists: $BUCKET_NAME"
        
        # Update encryption if needed
        print_info "Ensuring CMEK encryption on existing bucket..."
        gsutil kms encryption \
            -k "projects/$PROJECT_ID/locations/$REGION/keyRings/$KMS_KEYRING_NAME/cryptoKeys/$STORAGE_KEY_NAME" \
            "gs://$BUCKET_NAME"
        
        return 0
    fi
    
    # Create bucket without retention (by default)
    if gsutil mb -p "$PROJECT_ID" \
        -c STANDARD \
        -l "$LOCATION" \
        -b on \
        "gs://$BUCKET_NAME/"; then
        print_success "Created bucket: $BUCKET_NAME"
        
        # Apply CMEK encryption
        if gsutil kms encryption \
            -k "projects/$PROJECT_ID/locations/$REGION/keyRings/$KMS_KEYRING_NAME/cryptoKeys/$STORAGE_KEY_NAME" \
            "gs://$BUCKET_NAME"; then
            print_success "Applied CMEK encryption to bucket"
        else
            print_error "Failed to apply CMEK encryption"
            return 1
        fi
        
        # Set bucket labels
        gsutil label set <(echo "{
            \"purpose\": \"$BUCKET_PURPOSE\",
            \"compliance\": \"hipaa-fedramp\",
            \"encryption\": \"cmek\",
            \"environment\": \"production\"
        }") "gs://$BUCKET_NAME"
        
        # Optional: Set retention policy
        echo ""
        print_info "Retention policy for $BUCKET_DESCRIPTION"
        echo "By default, data will be kept indefinitely."
        if [ -n "$SUGGESTED_RETENTION" ]; then
            echo "Suggested retention: $SUGGESTED_RETENTION"
        fi
        echo ""
        read -p "Set a retention policy for this bucket? (yes/no): " SET_RETENTION
        
        if [ "$SET_RETENTION" = "yes" ]; then
            read -p "Enter retention period (e.g., 365d, 6y, 7y): " RETENTION_PERIOD
            
            if gsutil retention set "$RETENTION_PERIOD" "gs://$BUCKET_NAME/"; then
                print_success "Set $RETENTION_PERIOD retention policy"
                
                # Save retention info for summary
                case "$BUCKET_PURPOSE" in
                    "phi-storage")
                        PHI_RETENTION="$RETENTION_PERIOD"
                        ;;
                    "research-storage")
                        RESEARCH_RETENTION="$RETENTION_PERIOD"
                        ;;
                    "backup-storage")
                        BACKUP_RETENTION="$RETENTION_PERIOD"
                        ;;
                esac
            else
                print_error "Failed to set retention policy"
            fi
        else
            print_info "No retention policy set. Data will be kept indefinitely."
        fi
        
        return 0
    else
        print_error "Failed to create bucket: $BUCKET_NAME"
        return 1
    fi
}

# Create PHI data bucket
PHI_BUCKET="${PROJECT_ID}-phi-data"
create_encrypted_bucket \
    "$PHI_BUCKET" \
    "phi-storage" \
    "7y (HIPAA + 1 year buffer)" \
    "PHI data bucket"

# Create research data bucket
RESEARCH_BUCKET="${PROJECT_ID}-research-data"
create_encrypted_bucket \
    "$RESEARCH_BUCKET" \
    "research-storage" \
    "6y (HIPAA minimum)" \
    "research data bucket"

# Create backup bucket
BACKUP_BUCKET="${PROJECT_ID}-backups"
create_encrypted_bucket \
    "$BACKUP_BUCKET" \
    "backup-storage" \
    "1y (operational backups)" \
    "backup bucket"

# Uncomment below to create buckets with retention without prompting:
# gsutil retention set 7y "gs://$PHI_BUCKET/"
# gsutil retention set 6y "gs://$RESEARCH_BUCKET/" 
# gsutil retention set 365d "gs://$BACKUP_BUCKET/"

# Configure bucket lifecycle policies
print_info "Configuring lifecycle policies..."

# Create lifecycle policy for PHI bucket
cat > /tmp/phi_lifecycle.json <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {
          "type": "SetStorageClass",
          "storageClass": "NEARLINE"
        },
        "condition": {
          "age": 30,
          "matchesStorageClass": ["STANDARD"]
        }
      },
      {
        "action": {
          "type": "SetStorageClass",
          "storageClass": "COLDLINE"
        },
        "condition": {
          "age": 90,
          "matchesStorageClass": ["NEARLINE"]
        }
      },
      {
        "action": {
          "type": "SetStorageClass",
          "storageClass": "ARCHIVE"
        },
        "condition": {
          "age": 365,
          "matchesStorageClass": ["COLDLINE"]
        }
      }
    ]
  }
}
EOF

# Apply lifecycle policies
if gsutil lifecycle set /tmp/phi_lifecycle.json "gs://$PHI_BUCKET/"; then
    print_success "Applied lifecycle policy to PHI bucket"
else
    print_warning "Failed to apply lifecycle policy to PHI bucket"
fi

# Configure bucket IAM policies
print_info "Configuring bucket access policies..."

# Create bucket policy for PHI bucket
cat > /tmp/phi_bucket_policy.json <<EOF
{
  "bindings": [
    {
      "role": "roles/storage.objectViewer",
      "members": [
        "group:${RESEARCHERS_GROUP}"
      ],
      "condition": {
        "title": "Only from trusted networks",
        "description": "Access only from organization networks",
        "expression": "\"accessPolicies/${ACCESS_POLICY_NAME}/accessLevels/corp_network\" in request.auth.access_levels || \"accessPolicies/${ACCESS_POLICY_NAME}/accessLevels/on_prem_network\" in request.auth.access_levels"
      }
    },
    {
      "role": "roles/storage.objectAdmin",
      "members": [
        "group:${HEALTH_ADMINS_GROUP}"
      ]
    }
  ]
}
EOF

print_info "Bucket IAM policy example created. Apply manually with appropriate groups."

# Enable bucket versioning
print_info "Enabling versioning on critical buckets..."

for BUCKET in "$PHI_BUCKET" "$RESEARCH_BUCKET" "$BACKUP_BUCKET"; do
    if gsutil versioning set on "gs://$BUCKET/"; then
        check_status "Versioning enabled on $BUCKET"
    else
        check_status "Failed to enable versioning on $BUCKET"
    fi
done

# Configure uniform bucket-level access
print_info "Enabling uniform bucket-level access..."

for BUCKET in "$PHI_BUCKET" "$RESEARCH_BUCKET" "$BACKUP_BUCKET"; do
    if gsutil uniformbucketlevelaccess set on "gs://$BUCKET/"; then
        check_status "Uniform access enabled on $BUCKET"
    else
        check_status "Failed to enable uniform access on $BUCKET"
    fi
done

# Display bucket configuration
print_info "Storage configuration summary:"
echo "============================="

for BUCKET in "$PHI_BUCKET" "$RESEARCH_BUCKET" "$BACKUP_BUCKET"; do
    echo ""
    echo "Bucket: gs://$BUCKET/"
    gsutil ls -L -b "gs://$BUCKET/" | grep -E "(Encryption|Retention|Versioning|Lifecycle)" || true
done

# Clean up
rm -f /tmp/phi_lifecycle.json
rm -f /tmp/phi_bucket_policy.json

# Update state
save_state "STORAGE_ENCRYPTION_CONFIGURED" "true"
save_state "PHI_BUCKET" "$PHI_BUCKET"
save_state "RESEARCH_BUCKET" "$RESEARCH_BUCKET"
save_state "BACKUP_BUCKET" "$BACKUP_BUCKET"
save_state "STORAGE_CONFIGURED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
print_success "Storage encryption configured!"
echo ""
echo "Encrypted buckets created:"
echo -n "- PHI Data: gs://$PHI_BUCKET/"
if [ -n "$PHI_RETENTION" ]; then
    echo " ($PHI_RETENTION retention)"
else
    echo " (indefinite retention)"
fi
echo -n "- Research: gs://$RESEARCH_BUCKET/"
if [ -n "$RESEARCH_RETENTION" ]; then
    echo " ($RESEARCH_RETENTION retention)"
else
    echo " (indefinite retention)"
fi
echo -n "- Backups: gs://$BACKUP_BUCKET/"
if [ -n "$BACKUP_RETENTION" ]; then
    echo " ($BACKUP_RETENTION retention)"
else
    echo " (indefinite retention)"
fi
echo ""
echo "All buckets use:"
echo "- CMEK encryption with $STORAGE_KEY_NAME"
echo "- Versioning enabled"
echo "- Uniform bucket-level access"
echo "- Lifecycle transitions for cost optimization"
echo ""
echo "Next step: ./setup-secret-manager.sh"
