#!/usr/bin/env bash
# Delete everything created by the demo.
#   AWS_REGION=eu-west-3 bash tools/cleanup.sh [stack-name]
# 1) empties the log bucket (a non-empty bucket blocks stack deletion)
# 2) deletes the stack (the generated certificate is deleted by the stack)
# 3) deletes an ACM certificate you imported yourself, if you pass CERT_ARN
set -euo pipefail
STACK="${1:-pq-alb-demo}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[ -n "$REGION" ] || { echo "Set AWS_REGION first"; exit 1; }
BUCKET="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='LogBucketName'].OutputValue" --output text 2>/dev/null || true)"
if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  echo "Emptying s3://$BUCKET"
  aws s3 rm "s3://$BUCKET" --recursive --region "$REGION" --only-show-errors || true
fi
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
echo "Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "Stack deleted."
# The ALB may still deliver one last log file after the bucket was emptied; if so the bucket delete fails and
# the stack ends in DELETE_FAILED: run this script again.
if [ -n "${CERT_ARN:-}" ]; then
  aws acm delete-certificate --region "$REGION" --certificate-arn "$CERT_ARN" && echo "Certificate deleted."
fi
echo "If you supplied your own CertificateArn it is still in ACM (pass CERT_ARN=<arn> to delete it)."
