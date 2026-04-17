// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

var body = JSON.parse(context.getVariable("request.content"));
var model = body.model;

// Translate Anthropic model version format to Vertex AI format:
// claude-haiku-4-5-20251001 → claude-haiku-4-5@20251001
var versionMatch = model.match(/^(.+)-(\d{8})$/);
if (versionMatch) {
    model = versionMatch[1] + "@" + versionMatch[2];
}

var projectId = context.getVariable("propertyset.vertex_config.project_id");
var region = context.getVariable("propertyset.vertex_config.region") || "us-east5";
var action = (body.stream === true) ? "streamRawPredict" : "rawPredict";

var fullUrl = "https://" + region + "-aiplatform.googleapis.com" +
    "/v1/projects/" + projectId +
    "/locations/" + region +
    "/publishers/anthropic/models/" + model +
    ":" + action;

context.setVariable("target.url", fullUrl);

context.setVariable("claude.model", model);

body["anthropic_version"] = "vertex-2023-10-16";
delete body.model;
delete body.output_config;
context.setVariable("request.content", JSON.stringify(body));
