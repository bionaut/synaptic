# TODO

## Enterprise Guardrails

### Input Validation and Sanitization
- [ ] Enforce strict JSON Schema validation for all ingress paths, including workflow input, resume payloads, tool arguments, and MCP resources.
- [ ] Reject invalid or unknown fields instead of silently coercing malformed payloads to empty maps.
- [ ] Add field-level constraints: required fields, enums, length limits, numeric bounds, and regex validation.
- [ ] Canonicalize inputs before validation so equivalent malformed values cannot bypass rules.
- [ ] Add sanitizers for untrusted HTML, Markdown, URLs, filenames, and shell-like strings before they reach prompts or tools.

### Prompt Injection and Trust Boundaries
- [ ] Mark user input, MCP resources, retrieval results, and tool outputs as untrusted by default.
- [ ] Prevent untrusted content from overriding system or workflow instructions.
- [ ] Detect common prompt-injection and jailbreak patterns before model invocation.
- [ ] Add policy checks that block tool use when the prompt attempts data exfiltration, privilege escalation, or instruction override.

### Anti-Hallucination and Factuality
- [ ] Add an evidence-backed response mode for high-risk tasks.
- [ ] Require citations or explicit provenance when answers depend on provided context or tool results.
- [ ] Add abstention behavior when the system lacks sufficient evidence.
- [ ] Add optional verification passes for critical outputs before returning results.
- [ ] Detect unsupported claims in model output and either block them or downgrade confidence.

### Tool Safety
- [ ] Validate tool arguments against real schemas before dispatch.
- [ ] Reject extra properties and semantically invalid arguments before calling external tools.
- [ ] Sanitize tool results before they are reused as prompt content.
- [ ] Add idempotency, retry policy, rate limiting, and blast-radius controls for external actions.
- [ ] Add per-tool approval gates for risky or destructive operations.

### Policy Engine and Risk Controls
- [ ] Introduce a central policy layer for model usage, tool access, data classes, and tenant boundaries.
- [ ] Support per-agent and per-step allow/deny rules.
- [ ] Add risk tiers for low-risk chat, medium-risk automation, and high-risk external actions.
- [ ] Require human approval for actions above a configurable risk threshold.

### Security, Auditability, and Compliance
- [ ] Redact secrets and sensitive fields from logs, traces, workflow history, and events.
- [ ] Add immutable audit logs for prompts, tool calls, approvals, policy decisions, and blocked actions.
- [ ] Record policy decision reasons so denials are explainable.
- [ ] Support retention and deletion policies for workflow state and history.
- [ ] Add tenant isolation guarantees across prompts, traces, cached context, and tool results.

### Evaluation and Monitoring
- [ ] Build a guardrail regression suite covering validation failures, prompt injection, hallucination, and unsafe tool usage.
- [ ] Add adversarial test fixtures and red-team prompts.
- [ ] Track metrics for blocked requests, hallucination rate, policy denials, and unsafe tool-call attempts.
- [ ] Add dashboards or structured telemetry for guardrail outcomes.

## PII Protection

### PII Detection and Classification
- [ ] Detect common PII types locally before any LLM call, including email, phone, address, DOB, SSN, payment card data, and auth tokens.
- [ ] Support both pattern-based detection and field-aware classification.
- [ ] Tag values and fields with sensitivity levels such as `pii`, `restricted_pii`, and `secret`.
- [ ] Track provenance for sensitive data: user-provided, tool-derived, or model-generated.

### PII Redaction and Tokenization
- [ ] Add a pre-prompt redaction pipeline so direct identifiers are never sent to the LLM by default.
- [ ] Support disclosure policies per field: allow, mask, tokenize, or drop.
- [ ] Replace sensitive values with stable placeholders when the model needs structure but not raw identifiers.
- [ ] Rehydrate placeholders only after the model returns, and only when policy allows it.

### PII-Safe Validation Flow
- [ ] Validate PII locally with deterministic rules instead of sending raw values to the LLM for validation.
- [ ] Pass only derived facts to the model, such as `email_present`, `email_valid`, or `has_us_phone_number`.
- [ ] Add a secure mapping layer for placeholder-to-real-value lookup outside the model boundary.
- [ ] Prevent raw PII from being echoed back in model responses unless explicitly allowed.

### PII Policy and Governance
- [ ] Define policy rules such as "never send restricted PII to external LLMs".
- [ ] Restrict which tools and agents may access or export PII.
- [ ] Add configurable retention windows and deletion workflows for PII-bearing runs.
- [ ] Add audit events for when PII is detected, transformed, transmitted, blocked, or deleted.

## Suggested Implementation Order
- [ ] Phase 1: strict ingress validation, local PII detection, pre-prompt redaction, and tool-argument enforcement.
- [ ] Phase 2: policy engine, prompt-injection defenses, audit logging, and output filtering.
- [ ] Phase 3: evidence-backed response mode, verification passes, guardrail telemetry, and red-team evals.
