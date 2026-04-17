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
  exit
fi

if [ -z "$APIGEE_ENV" ]; then
  echo "No APIGEE_ENV variable set"
  exit
fi

echo "Installing apigeecli"
curl -s https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | bash
export PATH=$PATH:$HOME/.apigeecli/bin

TOKEN=$(gcloud auth print-access-token)

echo "Deleting developer apps..."
apigeecli apps delete \
  --name claude-standard-app \
  --email "$DEVELOPER_EMAIL" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

apigeecli apps delete \
  --name claude-power-app \
  --email "$DEVELOPER_EMAIL" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

echo "Deleting developer..."
apigeecli developers delete \
  --email "$DEVELOPER_EMAIL" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

echo "Deleting API products..."
apigeecli products delete \
  --name "claude-code-standard" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

apigeecli products delete \
  --name "claude-code-power" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

echo "Undeploying and deleting proxy..."
PROXY_REV=$(apigeecli apis get \
  --name "$PROXY_NAME" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null | jq -r '.deployments[0].revision' 2>/dev/null || echo "")

if [ -n "$PROXY_REV" ] && [ "$PROXY_REV" != "null" ]; then
  apigeecli apis undeploy \
    --name "$PROXY_NAME" \
    --rev "$PROXY_REV" \
    --org "$PROJECT" \
    --env "$APIGEE_ENV" \
    --token "$TOKEN" 2>/dev/null || true
fi

apigeecli apis delete \
  --name "$PROXY_NAME" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

echo "Deleting data collectors..."
apigeecli datacollectors delete \
  --name "dc_input_token_count" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

apigeecli datacollectors delete \
  --name "dc_output_token_count" \
  --org "$PROJECT" \
  --token "$TOKEN" 2>/dev/null || true

echo "Deleting property set..."
apigeecli res delete \
  --org "$PROJECT" \
  --env "$APIGEE_ENV" \
  --token "$TOKEN" \
  --name vertex_config 2>/dev/null || true

echo " "
echo "All Apigee artifacts have been removed."
