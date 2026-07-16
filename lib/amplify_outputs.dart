const amplifyConfig = '''{
  "auth": {
    "user_pool_id": "ap-southeast-1_QWojomuYD",
    "aws_region": "ap-southeast-1",
    "user_pool_client_id": "7grmh4ikdsr6mui7qlt6qen7b3",
    "identity_pool_id": "ap-southeast-1:8ff84085-b724-4f5d-b43f-64eb76053c05",
    "mfa_methods": [],
    "standard_required_attributes": [
      "email"
    ],
    "username_attributes": [
      "email"
    ],
    "user_verification_types": [
      "email"
    ],
    "groups": [],
    "mfa_configuration": "NONE",
    "password_policy": {
      "min_length": 8,
      "require_lowercase": true,
      "require_numbers": true,
      "require_symbols": true,
      "require_uppercase": true
    },
    "unauthenticated_identities_enabled": true
  },
  "storage": {
    "aws_region": "ap-southeast-1",
    "bucket_name": "amplify-d108r8994u20x9-ma-photobackupdrivebucketb1-tiaqtds1joi6",
    "buckets": [
      {
        "name": "photoBackupDrive",
        "bucket_name": "amplify-d108r8994u20x9-ma-photobackupdrivebucketb1-tiaqtds1joi6",
        "aws_region": "ap-southeast-1",
        "paths": {
          "full/\${cognito-identity.amazonaws.com:sub}/*": {
            "entityidentity": [
              "get",
              "list",
              "write",
              "delete"
            ]
          },
          "thumb/\${cognito-identity.amazonaws.com:sub}/*": {
            "entityidentity": [
              "get",
              "list",
              "write",
              "delete"
            ]
          }
        }
      }
    ]
  },
  "version": "1.3"
}''';
