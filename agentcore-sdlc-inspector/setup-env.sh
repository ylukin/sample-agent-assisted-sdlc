#!/bin/bash
# Fetches stack outputs and writes .env for the inspector POC.
# Usage: cd agentcore-sdlc-inspector && bash setup-env.sh

REGION="${AWS_REGION:-us-west-2}"
PROJECT=$(sed -nE 's/^project:[[:space:]]*([A-Za-z0-9-]+).*/\1/p' ../sdlc-config.yaml 2>/dev/null)
STACK_NAME="${1:-${PROJECT:-agent-assisted-sdlc}-assistant}"

echo "Fetching outputs from stack: $STACK_NAME (region: $REGION)..."

TABLE_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?contains(OutputKey,'SessionsTableName')].OutputValue" \
  --output text --region "$REGION" 2>/dev/null)

if [ -z "$TABLE_NAME" ] || [ "$TABLE_NAME" = "None" ]; then
  echo "ERROR: Could not find SessionsTableName output in stack $STACK_NAME"
  exit 1
fi

cat > .env <<EOF
AWS_REGION=$REGION
SESSIONS_TABLE_NAME=$TABLE_NAME
EOF

echo "Written .env:"
cat .env
