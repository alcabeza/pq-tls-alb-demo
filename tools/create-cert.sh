#!/usr/bin/env bash
# OPTIONAL: the stack now generates its own certificate. Use this only if you want to import one yourself
# (same Region as the stack) and pass it as CertificateArn.
#   AWS_REGION=eu-west-3 bash tools/create-cert.sh
# Prints the certificate ARN to pass as the CertificateArn parameter.
# The test client does not validate the chain: the demo is about the key exchange, not the certificate.
set -euo pipefail
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[ -n "$REGION" ] || { echo "Set AWS_REGION first (example: export AWS_REGION=eu-west-3)"; exit 1; }
DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 7 -sha256 \
  -subj "/CN=pq-demo.example.internal" -addext "subjectAltName=DNS:pq-demo.example.internal" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
ARN="$(aws acm import-certificate --region "$REGION" \
  --certificate "fileb://$DIR/cert.pem" --private-key "fileb://$DIR/key.pem" \
  --tags Key=Name,Value=pq-alb-demo --query CertificateArn --output text)"
echo "$ARN"
echo "Next: aws cloudformation deploy --region $REGION --stack-name pq-alb-demo --template-file template.yaml \\"
echo "        --capabilities CAPABILITY_IAM --parameter-overrides CertificateArn=$ARN"
