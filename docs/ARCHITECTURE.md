# Architecture Deep Dive: Apigee X as API Gateway for Claude Code

This document explains the architecture, design decisions, and implementation
details of using Apigee X as an API Gateway for Claude Code with Claude models
on Vertex AI. It also captures lessons learned from building and deploying this
solution.

## Table of Contents

- [Why This Architecture](#why-this-architecture)
- [How Claude Code Connects](#how-claude-code-connects)
- [Request Lifecycle](#request-lifecycle)
- [Payload Compatibility: Anthropic API vs Vertex AI](#payload-compatibility-anthropic-api-vs-vertex-ai)
- [Apigee Proxy Design](#apigee-proxy-design)
- [Streaming and Token Quotas with EventFlow](#streaming-and-token-quotas-with-eventflow)
- [GCP IAM and Service Accounts](#gcp-iam-and-service-accounts)
- [User Identification and Quota Tiers](#user-identification-and-quota-tiers)
- [Enterprise Deployment](#enterprise-deployment)
- [Security Considerations](#security-considerations)
- [Lessons Learned](#lessons-learned)

---

## Why This Architecture

Organizations adopting Claude Code need a way to:

1. **Control costs** -- LLM token consumption can be expensive; per-user quotas
   prevent runaway spend
2. **Centralize authentication** -- Developers should not need individual GCP
   credentials to access Vertex AI
3. **Gain observability** -- Track who is using how many tokens, on which models
4. **Enforce governance** -- Apply rate limits, content policies, and access
   tiers centrally

Apigee X sits between Claude Code and Vertex AI, providing all of the above
without modifying Claude Code itself.

```
Developer Machine                    GCP
+------------------+     HTTPS     +------------------+     HTTPS (internal)    +------------------------+
|                  |  ---------->  |                  |  --------------------->  |                        |
|   Claude Code    |               |    Apigee X      |                         |  Vertex AI (Claude)    |
|                  |  <----------  |                  |  <---------------------  |                        |
+------------------+    SSE        +------------------+       SSE               +------------------------+

 Sends:                             Does:                                        Serves:
 - Anthropic Messages API           - VerifyAPIKey (per-user)                    - Claude models via
 - x-api-key: <Apigee key>          - Token quota enforcement                     streamRawPredict
 - model, messages, stream:true     - Strip client auth, inject GCP OAuth2
                                     - URL path translation
                                     - SSE streaming pass-through
                                     - Token counting via EventFlow
```

---

## How Claude Code Connects

### Key Design Decision: Anthropic API Mode, NOT Vertex Mode

Claude Code is configured with `ANTHROPIC_BASE_URL` (standard Anthropic API
mode), **not** `CLAUDE_CODE_USE_VERTEX=1`.

**Why:** When `CLAUDE_CODE_USE_VERTEX=1` is set, Claude Code authenticates to
GCP itself (via ADC) and constructs Vertex AI URLs directly. By using
`ANTHROPIC_BASE_URL` instead, Claude Code sends standard Anthropic Messages API
requests to Apigee. Apigee handles all Vertex specifics: URL translation, auth
injection, and body modification. This cleanly separates developer machines
from GCP credentials.

### Developer Configuration

Each developer configures `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-apigee-host.example.com",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  },
  "apiKeyHelper": "echo APIGEE_CONSUMER_KEY_FOR_THIS_USER"
}
```

| Setting | Purpose |
|---------|---------|
| `ANTHROPIC_BASE_URL` | Redirects all Claude Code API traffic to Apigee |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | Prevents Claude Code from sending beta features unsupported by Vertex AI (e.g., `cache_control.scope`) |
| `apiKeyHelper` | Shell command whose stdout is sent as the `x-api-key` header. Must be used instead of `ANTHROPIC_API_KEY` (see [Lesson #10](#10-anthropic_api_key-validates-key-format----use-apikeyhelper-instead)) |

**Critical:** Ensure no Vertex-related env vars are set in the developer's
shell (`CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_VERTEX_PROJECT_ID`,
`CLOUD_ML_REGION`). These take precedence over `settings.json` and will route
traffic directly to Vertex AI, bypassing Apigee entirely (see
[Lesson #12](#12-vertex-related-environment-variables-override-the-gateway)).

### What Claude Code Calls

Claude Code makes exactly three types of API calls:

| Endpoint | Method | Handled By |
|----------|--------|------------|
| `/v1/messages` | POST | Routed to Vertex AI `streamRawPredict` / `rawPredict` |
| `/v1/messages/count_tokens` | POST | Routed to Vertex AI |
| `/v1/models` | GET | Served by Apigee as a static JSON response (no Vertex equivalent) |

### Example `~/.claude/settings.json`

Here is a complete working example of what a developer's Claude Code settings
file looks like when configured for this gateway:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-apigee-host.example.com",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  },
  "apiKeyHelper": "echo YOUR_APIGEE_CONSUMER_KEY"
}
```

Replace the host and key with values from your deployment. The deploy script
prints these values at the end of a successful run.

**Why `apiKeyHelper` instead of `ANTHROPIC_API_KEY`?** Claude Code validates
`ANTHROPIC_API_KEY` against Anthropic's key format (expects `sk-ant-*`). An
Apigee consumer key doesn't match this format, so Claude Code ignores it and
prompts for login. Using `apiKeyHelper` bypasses this validation entirely --
the command's stdout is sent as the `x-api-key` header with no format check.

### Dynamic API Keys (Optional)

For organizations that want short-lived tokens instead of static keys,
`apiKeyHelper` can run any script. For example, a script that exchanges a
corporate SSO token for a short-lived Apigee token:

```json
{
  "apiKeyHelper": "/usr/local/bin/get-apigee-token.sh"
}
```

The key refreshes every 5 minutes or on HTTP 401 (configurable via
`CLAUDE_CODE_API_KEY_HELPER_TTL_MS`).

---

## Request Lifecycle

A complete request through the gateway follows this path:

```
1. Claude Code sends POST /v1/messages with x-api-key header
   │
   ▼
2. Apigee ProxyEndpoint PreFlow (Request):
   ├── VA-VerifyAPIKey ──── Validates API key, populates developer/product vars
   ├── AM-SetModelVar ───── Extracts model name (normalized) and stream flag
   ├── LTQ-TokenEnforce ── Checks shared quota counter (EnforceOnly mode)
   │                        If over quota → 429 response, request stops
   │                        (conditional: only runs on POST /messages)
   └── AM-StripClientAuth ─ Removes x-api-key, Authorization, anthropic-version,
                             and anthropic-beta headers
   │
   ▼
2b. RouteRule selects TargetEndpoint based on claude.is_streaming:
    ├── "true"  → target-streaming  (response.streaming.enabled=true)
    └── "false" → target-nonstreaming (response body buffered normally)
   │
   ▼
3. Apigee TargetEndpoint PreFlow (Request) [both targets]:
   └── JS-ExtractModelAndBuildTargetUrl
       ├── Reads model from request body
       ├── Translates version format (claude-haiku-4-5-20251001 → claude-haiku-4-5@20251001)
       ├── Builds Vertex AI URL: https://{region}-aiplatform.googleapis.com/v1/projects/...
       ├── Sets target.url (overrides the placeholder URL in TargetEndpoint)
       ├── Adds anthropic_version: "vertex-2023-10-16" to body
       ├── Removes model field from body (Vertex AI rejects it as extra input)
       └── Removes output_config field (structured outputs not supported on Vertex AI)
   │
   ▼
4. Apigee HTTPTargetConnection [both targets]:
   ├── GoogleAccessToken automatically injects OAuth2 bearer token
   └── Request forwarded to Vertex AI
   │
   ▼
5. Vertex AI processes the request and returns response
   │
   ▼
6. Token counting (path depends on target):

   STREAMING PATH (target-streaming):
   └── EventFlow (per SSE event):
       └── LTQ-TokenCount ── Extracts usage.output_tokens from
                              response.event.current.data (CountOnly mode,
                              linked via SharedName to the enforce policy)

   NON-STREAMING PATH (target-nonstreaming):
   └── PostFlow Response:
       ├── JS-ExtractNonStreamTokens ── Parses response.content, extracts
       │                                 usage.output_tokens into flow variable
       └── LTQ-TokenCountNonStream ──── Reads flow variable to increment
                                         shared quota counter (CountOnly mode)
   │
   ▼
7. Apigee ProxyEndpoint PreFlow (Response):
   └── AM-AddQuotaHeaders ── Adds X-Token-Quota-Limit/Used/Remaining headers
   │
   ▼
8. Response delivered to Claude Code
```

---

## Payload Compatibility: Anthropic API vs Vertex AI

### Fields That Pass Through Unchanged

Vertex AI's `streamRawPredict` accepts the Anthropic Messages API body format
with minimal changes. These fields need no transformation:

| Field | Notes |
|-------|-------|
| `messages` | Identical format including multimodal content, tool_result, etc. |
| `max_tokens` | Same |
| `system` | Same (string or array of content blocks) |
| `temperature`, `top_p`, `top_k` | Same |
| `stream` | Same |
| `tools`, `tool_choice` | Same |
| `metadata` | Same |
| `stop_sequences` | Same |
| `thinking` (extended thinking) | Same (`{"type":"enabled","budget_tokens":N}`) |
| `cache_control` in messages | Same (ephemeral cache breakpoints) |

### Required Transformations

The JavaScript policy in the TargetEndpoint PreFlow performs these operations:

```javascript
// 1. Read model and translate version format
//    claude-haiku-4-5-20251001 → claude-haiku-4-5@20251001
var model = body.model;
var versionMatch = model.match(/^(.+)-(\d{8})$/);
if (versionMatch) {
    model = versionMatch[1] + "@" + versionMatch[2];
}

// 2. Build the full Vertex AI URL and set target.url
context.setVariable("target.url", "https://..." + model + ":streamRawPredict");

// 3. Add anthropic_version (required by Vertex AI, not sent by Claude Code)
body["anthropic_version"] = "vertex-2023-10-16";

// 4. Remove model from body (Vertex AI rejects it as "extra input")
delete body.model;

// 5. Remove output_config (structured outputs not yet supported on Vertex AI)
delete body.output_config;
```

Additionally, the AM-StripClientAuth policy removes headers that Vertex AI
does not expect: `x-api-key`, `Authorization`, `anthropic-version`, and
`anthropic-beta`.

Everything else in the body passes through unchanged. No deep JSON traversal,
no schema-specific transformations.

### Streaming Response Format

Vertex AI's `streamRawPredict` returns **identical SSE events** to the
Anthropic API:

```
event: message_start
data: {"type":"message_start","message":{"model":"claude-sonnet-4-6",...,"usage":{"input_tokens":12,...,"output_tokens":2}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello!"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn",...},"usage":{"input_tokens":12,...,"output_tokens":5}}

event: message_stop
data: {"type":"message_stop"}
```

Same event types, same JSON structure, same `usage` object. No response
transformation needed.

### Known Compatibility Issues

**`cache_control.scope`:** Claude Code may send a `scope` field inside
`cache_control` blocks (beta feature). Vertex AI rejects this with
`"Extra inputs are not permitted"`. **Solution:** Set
`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` on the Claude Code side.

**`output_config`:** Claude Code sends this field for structured output
(JSON schema enforcement), e.g. when generating session titles. Vertex AI
does not support it. **Solution:** Stripped in the JavaScript policy
(`delete body.output_config`).

**`anthropic-beta` header:** Claude Code sends beta feature flags like
`interleaved-thinking-2025-05-14` and `structured-outputs-2025-12-15`.
Vertex AI rejects unrecognized values. **Solution:** Stripped in
AM-StripClientAuth.

**Model version format:** Claude Code uses dash-separated versions
(`claude-haiku-4-5-20251001`) while Vertex AI uses `@`
(`claude-haiku-4-5@20251001`). **Solution:** Regex translation in the
JavaScript policy.

---

## Apigee Proxy Design

### Proxy Structure

```
apiproxy/
├── claude-code-gateway.xml              # Proxy metadata
├── proxies/
│   └── default.xml                      # ProxyEndpoint: auth, quota, routing
├── targets/
│   ├── target-streaming.xml             # Streaming: EventFlow token counting
│   └── target-nonstreaming.xml          # Non-streaming: PostFlow token counting
├── policies/
│   ├── VA-VerifyAPIKey.xml              # Validate x-api-key header
│   ├── AM-SetModelVar.xml               # Extract model + stream flag (JS wrapper)
│   ├── LTQ-TokenEnforce.xml             # Pre-request quota check (EnforceOnly)
│   ├── LTQ-TokenCount.xml               # SSE token counting in EventFlow (CountOnly)
│   ├── LTQ-TokenCountNonStream.xml      # JSON token counting in PostFlow (CountOnly)
│   ├── JS-ExtractModelAndBuildTargetUrl.xml  # URL translation (JS wrapper)
│   ├── JS-ExtractNonStreamTokens.xml    # Extract tokens from JSON response (JS wrapper)
│   ├── AM-StripClientAuth.xml           # Remove client auth + beta headers
│   ├── AM-StaticModelList.xml           # Static GET /v1/models response
│   ├── AM-AddQuotaHeaders.xml           # Add quota info to response headers
│   └── AM-QuotaError.xml               # 429 error in Anthropic format
└── resources/
    └── jsc/
        ├── SetModelVar.js               # Extracts model name + stream flag
        ├── ExtractModelAndBuildTargetUrl.js  # URL translation + body transform
        └── ExtractNonStreamTokens.js    # Token extraction from JSON response
```

### ProxyEndpoint Flow

The ProxyEndpoint handles authentication, quota enforcement, and routing:

- **PreFlow Request:** VerifyAPIKey → SetModelVar (extracts model name and
  `claude.is_streaming` flag) → TokenEnforce (conditional on POST /messages)
  → StripClientAuth
- **PreFlow Response:** AddQuotaHeaders (safe with streaming — only reads
  flow variables, never touches response.content)
- **Conditional Flows:** GET /v1/models returns a static response via
  AM-StaticModelList with a null RouteRule (no backend call)
- **FaultRules:** Quota violations return a 429 in Anthropic error format
- **RouteRules:** Routes to `target-streaming` when `claude.is_streaming =
  "true"`, otherwise to `target-nonstreaming`

### Dual TargetEndpoint Design

Two separate TargetEndpoints handle streaming and non-streaming responses
because `response.streaming.enabled=true` blocks access to `response.content`
for ALL responses, not just SSE (see [Lesson #17](#17-responsestreamingenabledblocks-all-response-body-access)).

**target-streaming:**
- `response.streaming.enabled=true` on the connection
- EventFlow with `LTQ-TokenCount` extracting from `response.event.current.data`
- SSE stream passes through to client in real-time

**target-nonstreaming:**
- No streaming properties (response body is buffered normally)
- PostFlow with `JS-ExtractNonStreamTokens` reading `response.content` and
  `LTQ-TokenCountNonStream` incrementing the shared quota counter

Both targets share the same:
- PreFlow Request with `JS-ExtractModelAndBuildTargetUrl`
- HTTPTargetConnection with `GoogleAccessToken` and `io.timeout.millis=300000`
- `SharedName: claude-token-quota` so both counting policies write to the
  same quota counter

### URL Path Translation

| Claude Code Sends | Apigee Forwards To |
|---|---|
| `POST /v1/messages` (stream:true) | `target-streaming` → `.../models/{MODEL}:streamRawPredict` |
| `POST /v1/messages` (stream:false) | `target-nonstreaming` → `.../models/{MODEL}:rawPredict` |
| `GET /v1/models` | Static response from Apigee (no backend call) |

---

## Streaming and Token Quotas with EventFlow

### The Challenge

Claude Code uses SSE streaming for nearly all requests. Token usage
(`usage.input_tokens`, `usage.output_tokens`) only appears in the
`message_delta` event near the end of the stream. The actual token cost is
unknown until the response is mostly delivered.

**Critical constraint:** Any Apigee policy that reads `response.content` when
streaming is enabled triggers full response buffering, defeating streaming
entirely. This means token counting **cannot** go in PostFlow. See
[Apigee antipattern: payload access with streaming](https://cloud.google.com/apigee/docs/api-platform/antipatterns/payload-with-streaming).

### The Solution: EventFlow + Split Enforcement

Apigee's **EventFlow** (GA in Apigee X) processes individual SSE events as
they stream through, without buffering the entire response. Combined with
split quota enforcement via `SharedName`:

```
Request Phase:                              Streaming Phase:
┌─────────────────────┐                    ┌──────────────────────────────────┐
│ ProxyEndpoint        │                    │ EventFlow (TargetEndpoint)       │
│ PreFlow Request      │                    │                                  │
│                      │                    │ Each SSE event passes through:   │
│ LTQ-TokenEnforce     │──SharedName───────>│ LTQ-TokenCount                   │
│   (EnforceOnly)      │  "claude-token-    │   (CountOnly)                    │
│   Checks counter,    │   quota"           │                                  │
│   rejects if over    │                    │ - message_start: has usage → count│
│   quota from prior   │  Same counter      │ - content_block_delta: skip      │
│   requests           │                    │ - message_delta: has usage → count│
│                      │                    │ - message_stop: skip             │
└─────────────────────┘                    └──────────────────────────────────┘
```

1. **PreFlow Request (EnforceOnly):** Checks the shared quota counter. If the
   user has already exceeded their limit from prior requests, reject with 429
   before calling Vertex AI.
2. **EventFlow Response (CountOnly):** Runs on every SSE event. Extracts token
   counts via JSONPath from `response.event.current.content`. Events without
   `usage` metadata (most events) are skipped automatically.

**Implication:** The request that pushes a user past their limit will complete.
The *next* request will be blocked. This one-request overshoot is inherent to
streaming and acceptable for this use case.

### EventFlow Constraints

- Maximum **4 policies** in the EventFlow Response element
- Supported policies: **LLMTokenQuota, JavaScript, MessageLogging,
  PublishMessage, RaiseFault, SanitizeModelResponses**
- AssignMessage, DataCapture, ExtractVariables, ServiceCallout, and most other
  policies are **NOT supported** in EventFlow
- `response.event.current.content` contains each SSE event's JSON data

### Timeout Configuration

LLM responses with extended thinking can take minutes. Apigee defaults are
too short:

| Property | Default | Recommended | Notes |
|----------|---------|-------------|-------|
| `io.timeout.millis` | 55,000 (55s) | 300,000 (5 min) | Set in TargetEndpoint properties |
| Load balancer timeout | 30s | Increase via GCP console | May also need adjustment |

---

## GCP IAM and Service Accounts

### Required Service Accounts

| Service Account | Role | Purpose |
|----------------|------|---------|
| Apigee runtime SA (auto-provisioned) | `roles/iam.serviceAccountTokenCreator` on the Vertex SA | Allows Apigee to mint OAuth2 tokens |
| Vertex AI SA (create this) | `roles/aiplatform.user` | Allows calling Vertex AI predict endpoints |

The proxy is deployed with `--sa <vertex-sa-email>` to bind the service account
to the proxy deployment. The `<GoogleAccessToken>` element in the
TargetEndpoint uses this SA to automatically generate and inject OAuth2 bearer
tokens.

### Setup Commands

```bash
# Create dedicated SA for Vertex AI access
gcloud iam service-accounts create apigee-vertex-sa \
    --display-name="Apigee to Vertex AI Service Account" \
    --project=YOUR-PROJECT-ID

# Grant Vertex AI access
gcloud projects add-iam-policy-binding YOUR-PROJECT-ID \
    --member="serviceAccount:apigee-vertex-sa@YOUR-PROJECT-ID.iam.gserviceaccount.com" \
    --role="roles/aiplatform.user"

# Allow Apigee runtime SA to impersonate this SA
PROJECT_NUMBER=$(gcloud projects describe YOUR-PROJECT-ID --format="value(projectNumber)")
gcloud iam service-accounts add-iam-policy-binding \
    apigee-vertex-sa@YOUR-PROJECT-ID.iam.gserviceaccount.com \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountTokenCreator"
```

---

## User Identification and Quota Tiers

### How Users Are Identified

Each user is identified by their **Apigee consumer key** (configured via
`apiKeyHelper` in Claude Code settings):

- 1 **Developer** entity in Apigee per user (keyed by corporate email)
- 1 **Developer App** per user, subscribed to an API Product
- App creation generates a **consumer key** sent by Claude Code as `x-api-key`

`VerifyAPIKey` resolves the key to `developer.email`, `client_id`, and product
quota settings, which feed into the LLMTokenQuota policies.

### Quota Tiers

Define tiers as separate API Products with different quota limits:

| Product | Daily Token Limit | Target Users |
|---------|------------------|--------------|
| `claude-code-standard` | 1,000,000 | Standard developers |
| `claude-code-power` | 5,000,000 | Senior engineers / power users |

Quotas are defined in the API Product's operation group JSON and automatically
referenced by the LLMTokenQuota policies via
`verifyapikey.VA-VerifyAPIKey.apiproduct.developer.quota.*` flow variables.

---

## Enterprise Deployment

### Managed Settings (Enforcing the Gateway Org-Wide)

To ensure developers cannot bypass Apigee, deploy managed settings:

**Linux:** `/etc/claude-code/managed-settings.json`
```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-apigee-host.example.com",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

The API key remains per-user (in `~/.claude/settings.json`). The managed
settings enforce the gateway URL and beta disable flag so no developer can
override them.

### Onboarding New Users

```bash
# Create developer in Apigee
apigeecli developers create --user jsmith \
  --email jsmith@company.com --first John --last Smith \
  --org "$PROJECT" --token "$TOKEN"

# Create app subscribed to the appropriate tier
apigeecli apps create --name jsmith-claude \
  --email jsmith@company.com --prods claude-code-standard \
  --org "$PROJECT" --token "$TOKEN" --disable-check

# Extract the consumer key
KEY=$(apigeecli apps get --name jsmith-claude \
  --org "$PROJECT" --token "$TOKEN" | jq -r '.[0].credentials[0].consumerKey')

# Send the key to the developer (securely)
echo "Add to ~/.claude/settings.json:"
echo "  \"apiKeyHelper\": \"echo $KEY\""
```

---

## Security Considerations

| Concern | Mitigation |
|---------|------------|
| API key leakage | Store in `~/.claude/settings.json` (mode 600); consider `apiKeyHelper` for short-lived tokens; rotate via Apigee multi-credential support |
| Developer bypasses Apigee | Developer never has GCP credentials; Vertex AI SA is only accessible to Apigee runtime SA; managed settings enforce the gateway URL |
| Quota gaming (rapid requests) | Distributed + synchronous quota counters; accept one-request overshoot (inherent to streaming) |
| Large prompt abuse | Add optional `PromptTokenLimit` policy for per-request input token spike arrest |
| Network eavesdropping | Apigee X uses Google-managed TLS; optionally enable mTLS |
| Key distribution | Deliver via secure channel (Vault, encrypted email); set credential expiration in Apigee |

---

## Lessons Learned

These are specific issues we encountered during implementation and deployment
that are not obvious from the documentation.

### 1. `model` Field Must Be Removed from the Request Body

**What we expected:** Vertex AI's `streamRawPredict` would ignore the `model`
field in the body since the model is specified in the URL path.

**What actually happened:** Vertex AI rejects the request with
`"model: Extra inputs are not permitted"`.

**Fix:** The JavaScript policy must `delete body.model` before forwarding.

### 2. `target.url` Must Be Set from the TargetEndpoint, Not ProxyEndpoint

**What we expected:** Setting `target.url` in a JavaScript policy running in
the ProxyEndpoint PreFlow would override the target URL.

**What actually happened:** The `target.url` variable set in the ProxyEndpoint
was ignored. The pathsuffix (`/messages`) was still appended to the static
`<URL>` in the TargetEndpoint.

**Fix:** Move the JS-ExtractModelAndBuildTargetUrl policy to the
**TargetEndpoint PreFlow**. Setting `target.url` there properly overrides the
entire outbound URL.

### 3. EventFlow Only Supports a Limited Set of Policies

**What we expected:** AssignMessage and DataCapture policies could run in
EventFlow alongside LLMTokenQuota.

**What actually happened:** Apigee rejects the proxy bundle at import time:
`"The EventFlow element references a policy named 'AM-ExtractTokenCount',
which either does not exist or is not one of JavaScript, MessageLogging,
PublishMessage, RaiseFault, SanitizeModelResponses, or LLMTokenQuota."`

**Fix:** Only use the explicitly supported policies in EventFlow. For analytics
data collection, use JavaScript policies within EventFlow or move data
capture to a non-streaming path.

### 4. LLMTokenQuota Requires a Model Name -- Even in EnforceOnly Mode

**What we expected:** The `LTQ-TokenEnforce` policy (EnforceOnly mode) would
only check the quota counter without needing to know the model.

**What actually happened:** The policy fails with
`"Failed to resolve model name"` when it runs on requests without a JSON body
(like GET /models).

**Fix:** Add a condition to the LTQ-TokenEnforce step so it only runs on
POST /messages:
```xml
<Step>
  <Name>LTQ-TokenEnforce</Name>
  <Condition>(proxy.pathsuffix MatchesPath "/messages") and (request.verb = "POST")</Condition>
</Step>
```

### 5. LLMModelSource Cannot Use JSONPath on SSE Events for Non-Google Models

**What we expected:** `<LLMModelSource>` could extract the model name from SSE
event data using JSONPath like
`{jsonPath('$.model',response.event.current.content,true)}`.

**What actually happened:** The model field is not present in every SSE event,
and the policy fails on events without it. The error persists even with
`continueOnError="true"`.

**Fix:** Save the model name as a flow variable in the JavaScript policy
(`context.setVariable("claude.model", model)`) and reference it in the
LLMTokenQuota policy:
```xml
<LLMModelSource>{claude.model}</LLMModelSource>
```

### 6. The TargetEndpoint URL Element Is Required but Gets Overridden

**What we expected:** We could omit the `<URL>` element from
HTTPTargetConnection since the JS dynamically sets `target.url`.

**What actually happened:** Apigee rejects the bundle:
`"The HTTPTargetConnection element must include a URL, Path, or LoadBalancer
element."`

**Fix:** Include a placeholder URL (`https://aiplatform.googleapis.com`) in
the TargetEndpoint. It gets fully overridden by `target.url` at runtime.

### 7. Apigee Validates ALL Policy Files in the Bundle

**What we expected:** Unused policy XML files (not referenced in any flow)
would be ignored during validation.

**What actually happened:** Apigee validates every XML file in the `policies/`
directory, even if no flow references it. A malformed DataCapture policy
(`<Capture>` vs `<Collect>` element name) caused an import failure even though
it was never attached to any flow.

**Fix:** Remove unused policy files from the bundle entirely, or ensure they
are valid even if unused.

### 8. Service Account Required for GoogleAccessToken Deployment

**What we expected:** `apigeecli apis deploy` would work without specifying a
service account.

**What actually happened:** Deployment fails with `MISSING_SERVICE_ACCOUNT`
because the proxy uses `<GoogleAccessToken>` in the TargetEndpoint.

**Fix:** Always deploy with the `--sa` flag:
```bash
apigeecli apis deploy --wait --name claude-code-gateway \
  --ovr --rev "$REV" --org "$PROJECT" --env "$APIGEE_ENV" \
  --token "$TOKEN" \
  --sa "your-vertex-sa@your-project.iam.gserviceaccount.com"
```

### 9. Claude Code Sends `x-api-key` (with dash), Not `x-apikey`

**What we expected:** Following the apigee-samples convention of
`<APIKey ref="request.header.x-apikey"/>`.

**What actually happened:** Claude Code sends the API key as `x-api-key`
(with a dash between "api" and "key"), following the Anthropic API convention.

**Fix:** Use `request.header.x-api-key` in the VerifyAPIKey policy.

### 10. `ANTHROPIC_API_KEY` Validates Key Format -- Use `apiKeyHelper` Instead

**What we expected:** Setting `ANTHROPIC_API_KEY` to the Apigee consumer key
would make Claude Code send it as the `x-api-key` header.

**What actually happened:** Claude Code validates `ANTHROPIC_API_KEY` against
Anthropic's key format (expects keys starting with `sk-ant-`). An Apigee
consumer key doesn't match, so Claude Code ignores it and prompts for OAuth
login. The OAuth login then generates a real Anthropic key that overrides the
env var entirely.

**Fix:** Use `apiKeyHelper` in `settings.json` instead of `ANTHROPIC_API_KEY`:
```json
{
  "apiKeyHelper": "echo YOUR_APIGEE_CONSUMER_KEY"
}
```
`apiKeyHelper` runs a shell command whose stdout becomes the API key. No
format validation is applied, so any string (including Apigee consumer keys)
works. Also make sure to `unset ANTHROPIC_API_KEY` and any Vertex-related
env vars (`CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_VERTEX_PROJECT_ID`,
`CLOUD_ML_REGION`) from your shell, as they take precedence and will bypass
the gateway.

### 11. Model Version Format Differs Between Anthropic API and Vertex AI

**What we expected:** Claude Code would send model names that map directly to
Vertex AI model IDs (e.g., `claude-haiku-4-5`).

**What actually happened:** Claude Code sends versioned model names using a
dash separator (`claude-haiku-4-5-20251001`), but Vertex AI expects the `@`
separator (`claude-haiku-4-5@20251001`). Unversioned names like
`claude-sonnet-4-6` work fine on both sides.

**Fix:** Add a regex translation in the JavaScript policy:
```javascript
var versionMatch = model.match(/^(.+)-(\d{8})$/);
if (versionMatch) {
    model = versionMatch[1] + "@" + versionMatch[2];
}
```

### 12. Vertex-Related Environment Variables Override the Gateway

**What we expected:** Setting `ANTHROPIC_BASE_URL` in `settings.json` would be
sufficient to route all traffic through Apigee.

**What actually happened:** Shell environment variables like
`CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_PROJECT_ID`, and
`CLOUD_ML_REGION` take precedence over `settings.json`. When set, Claude Code
uses the Vertex AI code path directly, bypassing `ANTHROPIC_BASE_URL` entirely.

**Fix:** Unset all Vertex-related env vars before launching Claude Code:
```bash
unset CLAUDE_CODE_USE_VERTEX ANTHROPIC_VERTEX_PROJECT_ID CLOUD_ML_REGION
```
For enterprise deployments, managed settings can enforce `ANTHROPIC_BASE_URL`,
but they cannot unset env vars already in the shell. Document this for users
who previously had Vertex AI configured.

### 13. `output_config` (Structured Outputs) Not Supported on Vertex AI

**What we expected:** All Anthropic Messages API fields would pass through to
Vertex AI's `streamRawPredict`.

**What actually happened:** Claude Code sends `output_config` with a JSON
schema for structured output (e.g., when generating session titles). Vertex AI
rejects this with a 400 error.

**Fix:** Remove `output_config` from the request body in the JavaScript policy:
```javascript
delete body.output_config;
```
This means structured output enforcement happens client-side (Claude Code
still sends the schema in the system prompt), but the strict JSON schema
validation by the API is lost. In practice, Claude still returns valid JSON.

### 14. `anthropic-beta` Header Must Be Stripped

**What we expected:** Beta headers would either be ignored or supported by
Vertex AI.

**What actually happened:** Claude Code sends `anthropic-beta` headers with
values like `interleaved-thinking-2025-05-14` and
`structured-outputs-2025-12-15` that Vertex AI does not recognize, causing
errors.

**Fix:** Strip the `anthropic-beta` header in AM-StripClientAuth alongside the
other auth headers:
```xml
<Header name="anthropic-beta"/>
```

### 15. API Products Must Use `llmOperationGroup` Not `operationGroup`

**What we expected:** Standard API Product `operationGroup` with `quota` would
work with `LLMTokenQuota` policies.

**What actually happened:** The `LLMTokenQuota` policy reads quota config from
`*.apiproduct.developer.llmQuota.*` flow variables, which are only populated
when the product uses `llmOperationGroup` with `llmTokenQuota`. Standard
`operationGroup` with `quota` populates `*.apiproduct.developer.quota.*`
(request-count quota), which LLMTokenQuota ignores silently.

**Fix:** Product JSON must use `llmOperations` and `llmTokenQuota`:
```json
{
  "operationConfigs": [{
    "apiSource": "claude-code-gateway",
    "llmOperations": [{"resource": "/", "methods": ["POST"], "model": "claude-sonnet-4-6"}],
    "llmTokenQuota": {"limit": "1000000", "interval": "1", "timeUnit": "day"}
  }],
  "operationConfigType": "proxy"
}
```
And `apigeecli` must use `--llmopgrp` (not `--opgrp`) to create the product.

### 16. EventFlow Variable Is `response.event.current.data`, Not `.content`

**What we expected:** `response.event.current.content` would contain the JSON
data from each SSE event, usable with jsonPath.

**What actually happened:** `.content` contains the **full SSE block** including
the `event:` and `data:` prefixes (e.g.,
`event: message_delta\ndata: {"usage":...}`). This is NOT valid JSON, so
jsonPath returns null and the token counter never increments.

**Fix:** Use `response.event.current.data` instead, which contains only the
JSON payload after the `data: ` prefix:
```xml
<LLMTokenUsageSource>{jsonPath('$.usage.output_tokens',response.event.current.data,true)}</LLMTokenUsageSource>
```

This was confirmed via Apigee debug trace showing `.content` =
`"event: message_start\ndata: {\"type\":..."` vs `.data` =
`"{\"type\":\"message_start\",..."`.

### 17. `response.streaming.enabled` Blocks ALL Response Body Access

**What we expected:** Setting `response.streaming.enabled=true` on the
TargetEndpoint would only affect SSE responses, and non-streaming JSON
responses would still be accessible via `response.content`.

**What actually happened:** The streaming property is connection-level, not
per-response. When enabled, `response.content` is inaccessible for ALL
responses — including non-streaming JSON. Any policy or JavaScript that reads
`response.content` either gets null or throws
`"Failed to resolve token usage count"`.

**Fix:** Use **two separate TargetEndpoints** routed by the request's `stream`
field:
- `target-streaming`: `response.streaming.enabled=true` + EventFlow for SSE
  token counting via `response.event.current.data`
- `target-nonstreaming`: no streaming property + PostFlow for JSON token
  counting via `response.content`

This is a common Apigee pattern when streaming and non-streaming responses
need different processing.

### 18. Dual TargetEndpoints Require Early Stream Detection

**What we expected:** We could detect streaming in the TargetEndpoint.

**What actually happened:** RouteRule evaluation happens before the
TargetEndpoint PreFlow. The `stream` field must be extracted from the request
body in the **ProxyEndpoint PreFlow** (via `SetModelVar.js`) and stored as a
flow variable for the RouteRule condition:
```xml
<RouteRule name="streaming">
  <Condition>claude.is_streaming = "true"</Condition>
  <TargetEndpoint>target-streaming</TargetEndpoint>
</RouteRule>
<RouteRule name="non-streaming">
  <TargetEndpoint>target-nonstreaming</TargetEndpoint>
</RouteRule>
```

### 19. `LLMTokenUsageSource` Requires Message Template Syntax, Not `ref`

**What we expected:** `<LLMTokenUsageSource ref="flow_variable"/>` would read
the token count from a flow variable.

**What actually happened:** The `ref` attribute is silently ignored. The
counter never increments.

**Fix:** Use message template syntax instead:
```xml
<LLMTokenUsageSource>{non_stream.output_tokens}</LLMTokenUsageSource>
```

### 20. LLM Operations Allow Only One Model Per `operationConfig`

**What we expected:** A single `operationConfig` could list multiple models
in `llmOperations`.

**What actually happened:** Apigee rejects with `"Operations must contain
exactly one entity but found N entities"`.

**Fix:** Create separate `operationConfig` entries for each model:
```json
{
  "operationConfigs": [
    {"apiSource": "proxy", "llmOperations": [{"model": "claude-sonnet-4-6", ...}], "llmTokenQuota": {...}},
    {"apiSource": "proxy", "llmOperations": [{"model": "claude-haiku-4-5", ...}], "llmTokenQuota": {...}},
    {"apiSource": "proxy", "llmOperations": [{"model": "claude-opus-4-7", ...}], "llmTokenQuota": {...}}
  ]
}
```
Each model gets its own quota counter. To share a single quota across models,
use the same `SharedName` in the policies.

### 21. Versioned Model Names Must Be Normalized for Product Matching

**What we expected:** Claude Code sending `claude-haiku-4-5-20251001` would
match a product with `model: "claude-haiku-4-5"`.

**What actually happened:** The `LLMModelSource` value must exactly match the
`model` field in the product's `llmOperations`. Claude Code sends versioned
names (`-YYYYMMDD` suffix) that don't match the base model name in the product.

**Fix:** `SetModelVar.js` normalizes the model name by stripping the date
suffix before setting `claude.model`:
```javascript
var versionMatch = model.match(/^(.+)-(\d{8})$/);
if (versionMatch) { model = versionMatch[1]; }
```

### 22. LLMTokenQuota Counts from Both `message_start` and `message_delta`

**What we expected:** The policy would only count tokens from the final
`message_delta` event.

**What actually happened:** Both `message_start` (with initial
`output_tokens`) and `message_delta` (with final cumulative `output_tokens`)
contain the `usage` field. The policy extracts and sums tokens from both
events, causing slight over-counting.

**Impact:** Minor — the over-count is typically 1-2 tokens from the initial
`message_start` event. For quota enforcement purposes this is negligible.

### 23. Property Sets Use Dot Notation in Variable References

The deploy script creates a property set named `vertex_config` with properties
`region` and `project_id`. In policies and JavaScript, these are referenced as:
```
propertyset.vertex_config.region
propertyset.vertex_config.project_id
```

Not `propertyset.vertex_config_region` or any other format.
