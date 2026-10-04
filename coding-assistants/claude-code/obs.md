# Claude Code Observability

How Claude Code telemetry flows from the AgentCore Runtime container into
CloudWatch / X-Ray / AgentCore Observability, and how to query it.

## Architecture

```
Claude Code (Node.js v2.1.x, runs in container)
  ├─ CLAUDE_CODE_ENABLE_TELEMETRY=1
  ├─ CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
  ├─ OTEL_LOG_TOOL_DETAILS=1
  └─ OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
        │
        ▼  unauthenticated OTLP/HTTP (protobuf)
ADOT Collector sidecar (same container, started by runtime/main.py)
  ├─ aws-otel-collector binary at /opt/aws/aws-otel-collector/bin/
  ├─ config: runtime/otel-collector-config.yaml
  ├─ listens on 127.0.0.1:4318 (HTTP) and :4317 (gRPC)
  ├─ extensions: sigv4auth (services xray + logs), region from AWS_REGION
  └─ exporters: otlphttp/xray, otlphttp/logs (compression: gzip)
        │
        ▼  SigV4-signed OTLP/HTTP
   ┌────────────────┴────────────────┐
   ▼                                  ▼
xray.<region>.amazonaws.com        logs.<region>.amazonaws.com
  /v1/traces                          /v1/logs
   │                                   │   x-aws-log-group=…
   ▼                                   ▼   x-aws-log-stream=otel-rt-logs
AWS X-Ray                           CloudWatch Logs
                                    /aws/bedrock-agentcore/runtimes/<id>-DEFAULT
                                    └─ stream: otel-rt-logs

Both streams are surfaced in the AgentCore Observability dashboard, linked
via cloud.resource_id (the runtime ARN) on every record's resource attrs.
```

## What Claude Code emits

Claude Code uses the **OTel Events API** (LogRecords with `body` =
event-name), **not** the Tracing API. Records have empty `traceId` /
`spanId` by design. This is intentional in v2.1.x.

| Event body                          | Purpose                                                  |
|-------------------------------------|----------------------------------------------------------|
| `claude_code.user_prompt`           | New user prompt received                                 |
| `claude_code.api_request`           | Amazon Bedrock model invocation (model, cost, tokens, duration) |
| `claude_code.tool_result`           | Tool call completed                                      |
| `claude_code.tool_decision`         | PreToolUse decision (allowed / blocked by hook)          |
| `claude_code.mcp_server_connection` | MCP gateway connect / disconnect                         |
| `claude_code.hook_registered`       | Hook discovered at startup                               |

All records carry these resource attributes (group / filter on these):

- `session.id` — runtime session ID (e.g. `sdlc-myorg-myrepo-issue-00042-run`)
- `gen_ai.conversation.id` — same value, GenAI semantic convention
- `service.name` — `agentcore_sdlc_claude_code.DEFAULT`
- `cloud.resource_id` — full runtime ARN
- `aws.log.group.names` / `aws.log.stream.names` — AgentCore log routing
- `service.version` — Claude Code version (e.g. `2.1.156`)

`session.id` is stamped via `OTEL_RESOURCE_ATTRIBUTES` exported in the
shell command that invokes `claude` — see
`project-management/shared/assistants/claude.py::_otel_attrs_prefix`.

### `claude_code.api_request` attributes

The richest record. Use this for cost / token / latency analytics.

| Attribute              | Example                          |
|------------------------|----------------------------------|
| `model`                | `claude-opus-4-7`                |
| `cost_usd`             | `0.00267`                        |
| `cost_usd_micros`      | `2670`                           |
| `input_tokens`         | `444`                            |
| `output_tokens`        | `18`                             |
| `cache_read_tokens`    | `0`                              |
| `cache_creation_tokens`| `0`                              |
| `duration_ms`          | `1008`                           |
| `prompt.id`            | UUID                             |
| `query_source`         | `generate_session_title` / `…`   |
| `effort`               | `xhigh` / `high` / `medium`      |
| `speed`                | `normal` / `fast`                |
| `event.sequence`       | Monotonic counter per session    |
| `event.timestamp`      | ISO 8601                         |
| `session.id`           | Runtime session ID (v2.1.288+;   |
|                        | was Claude's UUID in v2.1.156)   |

Note: in v2.1.156 each record had TWO session IDs — the runtime session ID
at the **resource** level and Claude's per-invocation UUID at the
**attribute** level. In v2.1.288 both carry the runtime session ID. Filter
on `resource.attributes.session.id` (no backticks — Logs Insights flattens
the nested JSON key into a plain dotted field name).

## Querying

All queries run against log group:

```
/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT
  └─ stream: otel-rt-logs
```

Replace `<RUNTIME_ID>` and `<SESSION_ID>` below.

To run these from the CLI, use `obs-query.sh`. It takes the TUI command
copied from the SDLC inspector and extracts the runtime, region and
session ID from it:

```bash
pbpaste | ./obs-query.sh events          # events | cost | tools | hooks | models
pbpaste | ./obs-query.sh cost --all      # invocations | subagents | complexity
./obs-query.sh tools --since 7d --cmd "agentcore exec --it --runtime arn:... --region us-west-2 --session-id sdlc-..."
```

If a query matches nothing, run `pbpaste | ./obs-query.sh discover --since 7d`
to list the log streams and session IDs that actually hold `claude_code.*`
events, then pass `--stream <name>` if it isn't `otel-rt-logs`.

Keep the queries in `obs-query.sh` in sync when editing the ones below.

### All events for one pipeline run

```sql
fields @timestamp, body,
       attributes.model, attributes.cost_usd,
       attributes.input_tokens, attributes.output_tokens,
       attributes.duration_ms, attributes.prompt.id
| filter @logStream = "otel-rt-logs"
| filter resource.attributes.session.id = "<SESSION_ID>"
| sort @timestamp asc
| limit 200
```

### Per-session cost rollup

```sql
fields resource.attributes.session.id as session,
       attributes.cost_usd as cost,
       attributes.input_tokens as input_tok,
       attributes.output_tokens as output_tok
| filter @logStream = "otel-rt-logs"
| filter body = "claude_code.api_request"
| stats sum(cost)      as total_cost_usd,
        sum(input_tok) as input_tokens,
        sum(output_tok) as output_tokens,
        count()        as api_calls
        by session
| sort total_cost_usd desc
| limit 50
```

### Tool usage across all sessions

```sql
fields attributes.tool_name as tool
| filter @logStream = "otel-rt-logs"
| filter body = "claude_code.tool_result"
| stats count() as calls by tool
| sort calls desc
```

### Hook decisions (PreToolUse blocks)

```sql
fields @timestamp, attributes.tool_name, attributes.decision,
       attributes.source, resource.attributes.session.id as session
| filter @logStream = "otel-rt-logs"
| filter body = "claude_code.tool_decision"
| sort @timestamp desc
| limit 100
```

### Models used + average latency by session

```sql
fields attributes.model as model, attributes.duration_ms as ms
| filter @logStream = "otel-rt-logs"
| filter body = "claude_code.api_request"
| stats avg(ms) as avg_ms, count() as calls by model
| sort calls desc
```

## Detecting subagents

The orchestrator skill (`plugin/skills/orchestrator/SKILL.md`) runs a
complexity check on each issue:

- **Path A — SIMPLE issue.** Orchestrator handles the pipeline inline,
  in one process. No Task subagents. Most issues land here.
- **Path B — COMPLEX issue.** Orchestrator delegates to `explore-agent`,
  `clarification-agent`, `implement-agent`, `critique-agent`, and
  `pr-agent` via the Task tool. Each Task call spawns a subagent visible
  in the logs as a `tool_result` with `attributes.tool_name = "Agent"`.

Two ways subagent-like activity shows up in `otel-rt-logs`:

1. **Separate `claude` invocations** — e.g. the strategy runs
   `claude mcp list` then `claude -p "..."`. Each spawns its own Claude
   process. As of v2.1.288 `attributes.session.id` carries the runtime
   session ID (from `OTEL_RESOURCE_ATTRIBUTES`), not a per-process UUID,
   so it no longer separates them. Each `claude -p` emits exactly one
   `claude_code.user_prompt`, so list those instead:

   ```sql
   fields @timestamp, attributes.prompt.id as prompt_id
   | filter @logStream = "otel-rt-logs"
   | filter resource.attributes.session.id = "<RUNTIME_SESSION_ID>"
   | filter body = "claude_code.user_prompt"
   | sort @timestamp asc
   ```

2. **Task tool subagents** (in-process, spawned by the orchestrator on
   Path B). Each subagent invocation appears as a `tool_result` record
   with `attributes.tool_name = "Agent"`:

   ```sql
   fields @timestamp, attributes.tool_name as tool,
          attributes.success as ok, attributes.duration_ms as ms
   | filter @logStream = "otel-rt-logs"
   | filter body = "claude_code.tool_result"
   | filter resource.attributes.session.id = "<RUNTIME_SESSION_ID>"
   | filter tool = "Agent"
   | sort @timestamp asc
   ```

   The nested `api_request` events from inside a Task subagent share the
   parent's `attributes.session.id`, so they are NOT distinguishable by
   Claude UUID alone. Claude Code v2.1.156 does not stamp
   `agent_id`/`parent_agent_id` attributes on these events
   (tracking [#42281](https://github.com/anthropics/claude-code/issues/42281)).
   To see the subagent's output, read the `tool_result` body — it
   contains the subagent's final response.

### Heuristic: was the issue SIMPLE or COMPLEX?

```sql
fields attributes.tool_name as tool
| filter @logStream = "otel-rt-logs"
| filter body = "claude_code.tool_result"
| filter resource.attributes.session.id = "<RUNTIME_SESSION_ID>"
| filter tool = "Agent"
| stats count() as subagent_calls
```

Result is `0` → orchestrator chose Path A (SIMPLE).
Result `>= 1` → Path B (COMPLEX); each Task call is one subagent.

## AgentCore Observability dashboard

Claude Code events are surfaced in the AgentCore Observability dashboard's
**Sessions** view, grouped automatically by the `session.id` resource
attribute. The **Traces** tab will be empty for Claude Code activity —
that's expected; Claude Code emits Events not Spans.

Probe traces emitted from the container's Python `aws_distro` (e.g. via
`/tmp/probe-otlp.sh`) DO appear in the Traces tab — they go through the
same sidecar collector with full Span structure. This confirms the
collector + IAM + endpoint path is healthy.

## Container-side debug

Verify the sidecar is up:

```bash
# Inside the container
ls -la /opt/aws/aws-otel-collector/bin/aws-otel-collector
curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  -X POST http://127.0.0.1:4318/v1/traces \
  -H "Content-Type: application/json" -d '{}'
# Expect: HTTP 200
```

Verify env on a `claude` invocation:

```bash
env | grep -E "CLAUDE|OTEL" | sort
# Should show OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
# and CLAUDE_CODE_ENABLE_TELEMETRY=1, etc.
```

Send a probe span (Python aws_distro inside the container) — appears in
X-Ray within ~30s:

```bash
/app/.venv/bin/python3 -c '
import os
os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://127.0.0.1:4318"
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
p = TracerProvider(resource=Resource.create({"service.name": "probe"}))
p.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(p)
with trace.get_tracer("probe").start_as_current_span("probe-span"):
    pass
p.force_flush(10000)
'
```

## Files involved

| File                                                      | Role                                              |
|-----------------------------------------------------------|---------------------------------------------------|
| `runtime/Dockerfile`                                      | Installs `aws-otel-collector` deb + Claude Code   |
| `runtime/otel-collector-config.yaml`                      | Receivers, sigv4auth, exporters, pipelines        |
| `runtime/main.py`                                         | Spawns collector before FastAPI, parses log headers |
| `lib/nested/assistant-stack.ts`                           | CDK env vars routing Claude Code to localhost:4318 |
| `lib/constructs/runtime/coding-assistant.ts`              | IAM (`xray:PutSpans`, `logs:PutLogEvents`)        |
| `project-management/shared/assistants/claude.py`          | `_otel_attrs_prefix` — stamps session.id          |

## Limitations

- **No trace tree.** Claude Code's events have empty `traceId` / `spanId`.
  AgentCore Observability "Traces" tab will not show Claude activity.
  Track upstream feature request:
  [anthropics/claude-code#42281 — \[FEATURE\] Native OTLP Trace/Span Export for Claude Code](https://github.com/anthropics/claude-code/issues/42281).
  When that ships, drop our LogRecord-based queries and switch to the
  span pipeline; the sidecar collector already accepts traces.
- **No metrics export.** Claude Code's `claude_code.token.usage` /
  `cost.usage` metrics target a localhost EMF endpoint we haven't bridged.
  Token/cost data is still available via the `claude_code.api_request`
  events — see queries above.
- **No `agent_id` / `parent_agent_id` on Task subagent events** in
  v2.1.156, so individual model calls inside a Task subagent can't be
  attributed back to the subagent invocation. Same upstream issue
  ([#42281](https://github.com/anthropics/claude-code/issues/42281)) will
  fix this.
- **PreToolUse stdout is invisible to runtime logs.** Hook stdout is
  consumed by Claude Code (used as the hook decision channel). To debug a
  PreToolUse hook, write to `/tmp/<hook>.log` and `cat` it via
  `execute_command` from the host.
