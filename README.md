# Claude Code Gateway

> This is not an officially supported Google product.

This sample demonstrates how to use Apigee X as an API Gateway for
[Claude Code](https://claude.ai/code), routing traffic to Claude models on
Vertex AI with per-user token-based quotas.

## Overview

Claude Code is configured to send standard Anthropic Messages API requests to
Apigee (via `ANTHROPIC_BASE_URL`). Apigee validates the user's API key, enforces
token quotas, translates the request to Vertex AI's `streamRawPredict` format,
and injects Google OAuth2 authentication. The SSE streaming response flows back
to the client in real-time while Apigee counts tokens via EventFlow.

```
Claude Code  -->  Apigee X  -->  Vertex AI (Claude)
             <--           <--
             SSE           SSE
```

### Key Features

- **Per-user token quotas** via LLMTokenQuota split enforcement (EnforceOnly + CountOnly)
- **SSE streaming** with EventFlow-based token counting (no response buffering)
- **Centralized GCP auth** -- developers never need GCP credentials
- **Tiered products** -- Standard (1M tokens/day) and Power (5M tokens/day)
- **Minimal body transformation** -- reads `model` for URL routing, adds
  `anthropic_version`, removes fields unsupported by Vertex AI

For a detailed architecture deep dive and lessons learned, see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Architecture

| Component | Role |
|-----------|------|
| Claude Code | Client -- sends Anthropic Messages API format |
| Apigee X ProxyEndpoint | Validates API key, enforces quota, strips client auth and beta headers |
| Apigee X TargetEndpoint | Translates URL and body for Vertex AI, injects GoogleAccessToken |
| Apigee X EventFlow | Counts tokens from SSE events without buffering |
| Vertex AI | Serves Claude models via `streamRawPredict` |

## Prerequisites

1. An Apigee X organization provisioned in your GCP project
2. Claude models enabled in Vertex AI (via Model Garden)
3. A GCP service account with `roles/aiplatform.user` that the Apigee runtime
   SA can impersonate (see IAM setup below)
4. [apigeecli](https://github.com/apigee/apigeecli) (installed automatically by
   the deploy script)
5. `gcloud` CLI authenticated with sufficient permissions
6. `jq` installed

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/carlosmscabral/claude-code-gateway.git
cd claude-code-gateway
```

Edit `env.sh` with your values:

```bash
export PROJECT="your-gcp-project-id"
export REGION="us-east5"                    # Vertex AI region for Claude
export APIGEE_HOST="your-apigee-hostname"   # e.g., api.example.com
export APIGEE_ENV="dev"                     # Apigee environment name
```

Source it:

```bash
source env.sh
```

### 2. Set up IAM (if not already done)

```bash
# Create service account for Vertex AI access
gcloud iam service-accounts create apigee-vertex-sa \
    --display-name="Apigee to Vertex AI" \
    --project=$PROJECT

# Grant Vertex AI access
gcloud projects add-iam-policy-binding $PROJECT \
    --member="serviceAccount:apigee-vertex-sa@$PROJECT.iam.gserviceaccount.com" \
    --role="roles/aiplatform.user"

# Allow Apigee runtime SA to impersonate it
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format="value(projectNumber)")
gcloud iam service-accounts add-iam-policy-binding \
    apigee-vertex-sa@$PROJECT.iam.gserviceaccount.com \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountTokenCreator"
```

### 3. Deploy

The deploy script requires the `--sa` flag for proxies using
`<GoogleAccessToken>`. Edit the `SA_EMAIL` variable at the top of
`deploy-claude-code-gateway.sh`, or pass an existing SA with
`roles/aiplatform.user`:

```bash
bash deploy-claude-code-gateway.sh
```

The script will output the consumer keys and Claude Code configuration.

### 4. Configure Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://YOUR_APIGEE_HOST",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  },
  "apiKeyHelper": "echo YOUR_CONSUMER_KEY"
}
```

**Important:** Use `apiKeyHelper` (not `ANTHROPIC_API_KEY`) because Claude Code
validates `ANTHROPIC_API_KEY` against Anthropic's key format (`sk-ant-*`).
Apigee consumer keys don't match, causing Claude Code to ignore them and prompt
for login. `apiKeyHelper` bypasses this validation.

Also ensure no Vertex-related env vars are set in your shell
(`CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION`)
as they will override the gateway configuration and route traffic directly to
Vertex AI.

### 5. Test

```bash
# Non-streaming test via curl
curl -X POST \
  -H "x-api-key: YOUR_CONSUMER_KEY" \
  -H "Content-Type: application/json" \
  "https://$APIGEE_HOST/v1/messages" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Hello"}],"max_tokens":50,"stream":false}'

# Streaming test
curl -X POST \
  -H "x-api-key: YOUR_CONSUMER_KEY" \
  -H "Content-Type: application/json" \
  "https://$APIGEE_HOST/v1/messages" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Hello"}],"max_tokens":50,"stream":true}' \
  --no-buffer

# Claude Code test
claude -p "say hello"
```

## Cleanup

```bash
bash undeploy-claude-code-gateway.sh
```

## How It Works

### ProxyEndpoint -- Request PreFlow

1. **VA-VerifyAPIKey** -- validates the `x-api-key` header
2. **AM-SetModelVar** -- extracts model name (normalized to base name) and
   `stream` flag from the request body. Sets `claude.model` and
   `claude.is_streaming` flow variables
3. **LTQ-TokenEnforce** -- checks the shared token quota counter (EnforceOnly
   mode). Conditional on `POST /messages` only
4. **AM-StripClientAuth** -- removes `x-api-key`, `Authorization`,
   `anthropic-version`, and `anthropic-beta` headers

### Routing

RouteRules select the TargetEndpoint based on `claude.is_streaming`:
- `stream: true` -> **target-streaming** (SSE pass-through + EventFlow)
- `stream: false` -> **target-nonstreaming** (buffered response + PostFlow)

Two targets are needed because `response.streaming.enabled=true` makes
`response.content` inaccessible for ALL responses, preventing token counting
on non-streaming requests.

### TargetEndpoint -- Request PreFlow (both targets)

5. **JS-ExtractModelAndBuildTargetUrl** -- the core translation logic:
   - Translates model version format (`-YYYYMMDD` -> `@YYYYMMDD`)
   - Builds the full Vertex AI URL and sets `target.url`
   - Adds `anthropic_version: "vertex-2023-10-16"` to the body
   - Removes `model` and `output_config` from the body

### Token Counting (path depends on target)

**Streaming (target-streaming):**

6a. **LTQ-TokenCount** -- runs in EventFlow on each SSE event. Extracts
    `usage.output_tokens` from `response.event.current.data` (CountOnly mode,
    linked via SharedName to the enforce policy)

**Non-streaming (target-nonstreaming):**

6b. **JS-ExtractNonStreamTokens** -- parses `response.content` and extracts
    `usage.output_tokens` into a flow variable

6c. **LTQ-TokenCountNonStream** -- reads the flow variable to increment the
    shared quota counter (CountOnly mode, same SharedName)

### ProxyEndpoint -- Response PreFlow

7. **AM-AddQuotaHeaders** -- adds `X-Token-Quota-Limit`, `X-Token-Quota-Used`,
   `X-Token-Quota-Remaining` response headers

### Static Endpoints

- **GET /v1/models** -- returns a static model list (no Vertex AI equivalent)

### Fault Handling

- **AM-QuotaError** -- returns a 429 in Anthropic error format when quota is
  exceeded

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.
