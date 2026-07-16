const amplifyConfig = '''{
  "version": "1",
  "auth": {
    "aws_region": "us-east-1",
    "user_pool_id": "us-east-1_placeholder",
    "user_pool_client_id": "placeholderclientid",
    "identity_pool_id": "us-east-1:placeholder-identity-pool-id",
    "standard_required_attributes": ["email"],
    "username_attributes": ["email"],
    "user_verification_types": ["email"],
    "unauthenticated_identities_enabled": true,
    "password_policy": {
      "min_length": 8,
      "require_lowercase": true,
      "require_uppercase": true,
      "require_numbers": true,
      "require_symbols": true
    }
  },
  "storage": {
    "aws_region": "us-east-1",
    "bucket_name": "placeholder-bucket-name"
  }
}''';
