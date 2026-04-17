#!/bin/bash

# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

PROXY_NAME="claude-code-gateway"
DEVELOPER_EMAIL="claude_apigeesamples@acme.com"

if [ -z "$PROJECT" ]; then
  echo "No PROJECT variable set"
  exit 1
fi

if [ -z "$APIGEE_ENV" ]; then
  echo "No APIGEE_ENV variable set"
  exit 1
fi

if [ -z "$APIGEE_HOST" ]; then
  echo "No APIGEE_HOST variable set"
  exit 1
fi

if [ -z "$REGION" ]; then
  echo "No REGION variable set"
  exit 1
fi

echo "Installing apigeecli"
curl -s https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | bash
export PATH=$PATH:$HOME/.apigeecli/bin

TOKEN=$(gcloud auth print-access-token)

# -------------------------------------------------------------------
# Step 1: Create property set for Vertex AI configuration
# -------------------------------------------------------------------
echo "Creating Vertex AI property set..."
echo -e "region=$REGION\nproject_id=$PROJECT" > vertex_config.properties

apigeecli res create \
  --org "$PROJECT" \
  --env "$APIGEE_ENV" \
  --token "$TOKEN" \
  --name vertex_config \
  --type properties \
  --respath vertex_config.properties 2>/dev/null || \
apigeecli res update \
  --org "$PROJECT" \
  --env "$APIGEE_ENV" \
  --token "$TOKEN" \
  --name vertex_config \
  --type properties \
  --respath vertex_config.properties 2>/dev/null || true

rm -f vertex_config.properties

# -------------------------------------------------------------------
# Step 2: Create data collectors for token analytics
# -------------------------------------------------------------------
echo "Creating data collectors..."
apigeecli datacollectors create \
  --name "dc_input_token_count" \
  --type "integer" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

apigeecli datacollectors create \
  --name "dc_output_token_count" \
  --type "integer" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

# -------------------------------------------------------------------
# Step 3: Import and deploy API proxy
# -------------------------------------------------------------------
echo "Importing and deploying $PROXY_NAME proxy..."
REV=$(apigeecli apis create bundle \
  -f ./apiproxy \
  -n "$PROXY_NAME" \
  --org "$PROJECT" \
  --token "$TOKEN" \
  --disable-check | jq ."revision" -r)

apigeecli apis deploy --wait \
  --name "$PROXY_NAME" \
  --ovr \
  --rev "$REV" \
  --org "$PROJECT" \
  --env "$APIGEE_ENV" \
  --token "$TOKEN"

echo "Proxy $PROXY_NAME revision $REV deployed to $APIGEE_ENV"

# -------------------------------------------------------------------
# Step 4: Create API Products (Standard and Power tiers)
# -------------------------------------------------------------------
echo "Creating API Products..."
apigeecli products create \
  --name "claude-code-standard" \
  --display-name "Claude Code - Standard" \
  --envs "$APIGEE_ENV" \
  --approval auto \
  --attrs "access=public" \
  --llmopgrp ./aiproduct-standard.json \
  --org "$PROJECT" \
  --token "$TOKEN"

apigeecli products create \
  --name "claude-code-power" \
  --display-name "Claude Code - Power" \
  --envs "$APIGEE_ENV" \
  --approval auto \
  --attrs "access=public" \
  --llmopgrp ./aiproduct-power.json \
  --org "$PROJECT" \
  --token "$TOKEN"

# -------------------------------------------------------------------
# Step 5: Create developer
# -------------------------------------------------------------------
echo "Creating developer..."
apigeecli developers create \
  --user testuser \
  --email "$DEVELOPER_EMAIL" \
  --first Test \
  --last User \
  --org "$PROJECT" \
  --token "$TOKEN"

# -------------------------------------------------------------------
# Step 6: Create developer apps (one per tier)
# -------------------------------------------------------------------
echo "Creating developer apps..."
apigeecli apps create \
  --name claude-standard-app \
  --email "$DEVELOPER_EMAIL" \
  --prods claude-code-standard \
  --org "$PROJECT" \
  --token "$TOKEN" \
  --disable-check

apigeecli apps create \
  --name claude-power-app \
  --email "$DEVELOPER_EMAIL" \
  --prods claude-code-power \
  --org "$PROJECT" \
  --token "$TOKEN" \
  --disable-check

# -------------------------------------------------------------------
# Step 7: Extract consumer keys
# -------------------------------------------------------------------
STANDARD_KEY=$(apigeecli apps get \
  --name claude-standard-app \
  --org "$PROJECT" \
  --token "$TOKEN" | jq ."[0].credentials[0].consumerKey" -r)

POWER_KEY=$(apigeecli apps get \
  --name claude-power-app \
  --org "$PROJECT" \
  --token "$TOKEN" | jq ."[0].credentials[0].consumerKey" -r)

# -------------------------------------------------------------------
# Output
# -------------------------------------------------------------------
echo " "
echo "All Apigee artifacts are successfully deployed!"
echo " "
echo "=============================================="
echo "  Claude Code Gateway Configuration"
echo "=============================================="
echo " "
echo "Proxy endpoint: https://$APIGEE_HOST/v1/messages"
echo " "
echo "Standard tier key: $STANDARD_KEY"
echo "  (1,000,000 tokens/day)"
echo " "
echo "Power tier key:    $POWER_KEY"
echo "  (5,000,000 tokens/day)"
echo " "
echo "----------------------------------------------"
echo "  Claude Code Setup (add to ~/.claude/settings.json)"
echo "----------------------------------------------"
echo " "
echo '{
  "env": {
    "ANTHROPIC_BASE_URL": "https://'"$APIGEE_HOST"'",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  },
  "apiKeyHelper": "echo '"$STANDARD_KEY"'"
}'
echo " "
echo "----------------------------------------------"
echo "  Quick Test"
echo "----------------------------------------------"
echo " "
echo "curl -X POST -H \"x-api-key: $STANDARD_KEY\" \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  \"https://$APIGEE_HOST/v1/messages\" \\"
echo "  -d '{\"model\":\"claude-sonnet-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50,\"stream\":false}'"
echo " "
