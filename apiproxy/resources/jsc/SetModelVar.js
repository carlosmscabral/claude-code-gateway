// Extract model and stream flag from request body.
// Normalizes versioned model names: claude-haiku-4-5-20251001 → claude-haiku-4-5
var body = JSON.parse(context.getVariable("request.content"));
var model = body.model || "";
var versionMatch = model.match(/^(.+)-(\d{8})$/);
if (versionMatch) {
    model = versionMatch[1];
}
context.setVariable("claude.model", model);
context.setVariable("claude.is_streaming", (body.stream === true) ? "true" : "false");
