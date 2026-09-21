# Architecture

## Design goal

ChatGPT-Export is an inventory-first archival system, not a page scraper. A run discovers every supported remote history scope before it considers individual conversation capture complete.

## Components

1. **FastAPI control plane** — local web UI and authenticated management endpoints.
2. **SecretStore** — Fernet-encrypted ChatGPT session JSON at rest; encryption key remains root-only in `/etc/chatgpt-export`.
3. **Provider adapter** — a narrow allowlist of read-only relative ChatGPT web endpoints, with bounded retries, shared rate-limit cooldown and strict response limits.
4. **Inventory engine** — paginates main, archived, Projects, project conversations and shared conversations to normal termination; detects repeated pages, cursor cycles, premature empty pages and stalled offsets.
5. **Capture engine** — stores immutable raw conversation payloads, membership evidence, derived Markdown and available assets.
6. **SQLite state** — WAL-backed job state and per-object resume metadata.
7. **Validation layer** — produces `COMPLETE` only when every supported scope and object verifies.

## State transitions

A job can end as:

- `COMPLETE` — every supported discovered item was verified;
- `PARTIAL` — export produced useful data but one or more scopes/assets/artifacts remain unresolved;
- `AUTH_REQUIRED` — ChatGPT rejected the bearer token; paste a fresh session and resume;
- `FAILED` — a fatal local/runtime error prevented a trustworthy run;
- `INTERRUPTED` — the service restarted before a prior run reached a terminal state. A replacement run is automatically created when a usable encrypted session is available.

Individual conversations use a durable marker written last:

```text
listing discovered
→ raw.json written atomically
→ membership.json written
→ Markdown derived
→ assets attempted
→ complete.json written last
```

The raw payload is authoritative. Derived Markdown can be regenerated.

## Workspace behavior

The exporter probes the account-check endpoint and captures each unique active account/workspace ID exposed by ChatGPT. It does not add a guessed headerless duplicate scope. Account IDs are not used as folder names; local workspace folder keys use a namespaced one-way SHA-256 fingerprint prefix.

## Resume and delta behavior

SQLite records the last remote update value and verified local object path. If a conversation has the same remote update marker and a valid local completion marker, a later run skips its body download. Inventory still runs again so newly created, moved, archived or project-only conversations are discovered.

Remote deletions are not automatically deleted locally. This is a backup system, not a destructive mirror. If the service restarts while a job is `QUEUED` or `RUNNING`, that job is marked `INTERRUPTED` and a new resumable run is started from the encrypted session when possible.
