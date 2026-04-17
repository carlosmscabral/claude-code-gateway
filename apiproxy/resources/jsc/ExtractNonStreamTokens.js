var content = context.getVariable("response.content");
if (content) {
    try {
        var resp = JSON.parse(content);
        if (resp.usage && resp.usage.output_tokens) {
            context.setVariable("non_stream.output_tokens", String(resp.usage.output_tokens));
        }
    } catch(e) {}
}
