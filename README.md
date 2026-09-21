# ChatGPT-Export

**ChatGPT-Export** is a self-hosted, resumable backup server for data exposed by the authenticated ChatGPT web application. It is designed for one-click installation on a Linux VPS, then accepts the owner's `https://chatgpt.com/api/auth/session` JSON and immediately begins a read-only export.

> [!IMPORTANT]
> This is an **unofficial** exporter built on private ChatGPT web endpoints. Those endpoints can change without notice. The project deliberately reports `PARTIAL` or `AUTH_REQUIRED` rather than claiming a complete backup when verification fails.

> [!WARNING]
> `/api/auth/session` contains a bearer credential. Treat it like a password. Use this project only on infrastructure you control. Keep the service bound to loopback until you put a trusted authenticated HTTPS reverse proxy in front of it.

## What it captures

The current contract covers:

- main conversation history;
- archived conversation history;
- every discovered Project;
- every discovered conversation inside each Project;
- raw project metadata and project file descriptors;
- owned/shared conversation inventory and share detail;
- full raw conversation graphs;
- uploaded/generated file references that can still be resolved;
- project files that can still be resolved;
- memories exposed by the web app;
- custom instructions / user system messages;
- settings and beta-feature settings;
- custom GPT inventory;
- workspace/account scopes exposed by the account-check endpoint.

Every conversation keeps `raw.json` as the archival source of truth. Markdown is derived only for convenient reading.

## Completeness model

`COMPLETE` does **not** mean byte-for-byte equivalence with OpenAI's official data export. It means:

1. every supported server-side inventory chain terminated normally;
2. every conversation ID discovered in those chains has a durable local `complete.json` marker;
3. raw payloads were written atomically and hashed;
4. all expected assets discovered by the current adapters were captured successfully;
5. account artifacts and shared/project scopes completed without unresolved errors.

If an endpoint changes, an asset expires, authentication expires, a page loops, or a scope fails, the run is `PARTIAL`, `AUTH_REQUIRED`, or `FAILED` — never falsely green.

## One-click install

On a Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/ZTD38F/ChatGPT-Export/main/install.sh | sudo bash
```

The installer:

- checks Linux, CPU, package manager and init system;
- installs only missing prerequisites;
- downloads the repository into a versioned release directory;
- builds an isolated Python virtual environment;
- compiles/import-tests the application before activation;
- generates a service-isolated Fernet encryption key;
- generates a service-isolated random admin token;
- creates a `systemd` or OpenRC service when available;
- activates the release atomically;
- restores the previous release/config/service definition if activation fails;
- health-checks the live service several times;
- runs a SQLite/storage doctor;
- rolls activation back if verification fails.

The service binds to `127.0.0.1:8788` by default.

## First export

1. Sign in to ChatGPT in your normal browser.
2. Open `https://chatgpt.com/api/auth/session`.
3. Copy the complete JSON object.
4. Open the self-hosted ChatGPT-Export UI through your trusted tunnel/reverse proxy.
5. Obtain the server admin token:

```bash
sudo chatgpt-exportctl admin-token
```

6. Paste the admin token once.
7. Paste the session JSON and press **Connect & start full export**.

The session is checked against ChatGPT before it is stored. The export then starts immediately in the background. Closing the browser UI does not cancel the server worker. If the service restarts mid-run, the stale job is marked `INTERRUPTED` and a replacement run automatically resumes from durable state when the stored session is still usable.

## Session expiry

The pasted access token is short-lived. ChatGPT-Export encrypts the session JSON at rest, but it cannot mint a new ChatGPT web token without a browser-authenticated refresh mechanism. If ChatGPT returns an authentication failure (normally `401`), the run becomes `AUTH_REQUIRED`; a `403` during initial session preflight is rejected before the session is stored. Paste a fresh `/api/auth/session` JSON; the next run resumes from durable state and skips already-verified, unchanged conversations.

This behavior is intentional: the server never asks for your Google/OpenAI password and never stores browser cookies by default.

## Output layout

```text
/var/lib/chatgpt-export/data/
├── latest-validation.json
├── archive/
│   └── workspaces/
│       └── <workspace-key>/
│           ├── account/
│           │   ├── memories.json
│           │   ├── custom_instructions.json
│           │   ├── settings.json
│           │   └── beta_features.json
│           ├── conversations/
│           │   └── <conversation-id>/
│           │       ├── raw.json
│           │       ├── listing.json
│           │       ├── membership.json
│           │       ├── conversation.md
│           │       ├── assets/
│           │       └── complete.json
│           ├── projects/             ← project.json + conversation-index.json per Project
│           ├── project-files/
│           ├── shared/
│           └── gpts/
└── runs/
    └── <run-id>/
        ├── source/...
        ├── workspaces/.../inventory.json
        └── validation.json
```

`runs/` preserves the evidence used to prove inventory completeness. `archive/` is the durable latest-known local mirror.

## Management

```bash
sudo chatgpt-exportctl status
sudo chatgpt-exportctl logs
sudo chatgpt-exportctl doctor
sudo chatgpt-exportctl export-status
sudo chatgpt-exportctl restart
sudo chatgpt-exportctl stop
sudo chatgpt-exportctl data-dir
```

## Safe preview

```bash
git clone https://github.com/ZTD38F/ChatGPT-Export.git
cd ChatGPT-Export
sudo ./install.sh --dry-run
```

## Update

```bash
curl -fsSL https://raw.githubusercontent.com/ZTD38F/ChatGPT-Export/main/update.sh | sudo bash
```

Updates use the same isolated-release and activation verification path as installation.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ZTD38F/ChatGPT-Export/main/uninstall.sh | sudo bash
```

The uninstaller deliberately preserves `/etc/chatgpt-export` and `/var/lib/chatgpt-export`. It will not destroy backups or credentials automatically.

## Security principles

- read-only ChatGPT operations only;
- no archive/delete/rename/share/edit operations;
- bearer token never printed to logs;
- session JSON encrypted at rest;
- non-world-readable key and admin token, restricted to root and the dedicated service account;
- no bearer token is sent to signed asset hosts;
- signed asset URLs are redacted from metadata files;
- asset downloads reject local/private/reserved DNS destinations;
- service binds to loopback by default;
- systemd hardening and restrictive umask;
- atomic writes and completion markers;
- no silent fallback to DOM scraping when an API contract drifts.

See [docs/SECURITY.md](docs/SECURITY.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/WEB_CONTRACT.md](docs/WEB_CONTRACT.md), and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Disclaimer

This project is not affiliated with or endorsed by OpenAI. It uses undocumented ChatGPT web endpoints for backup of data accessible to the authenticated account owner. Endpoint behavior, service terms, rate limits and available data can change. Use it only for accounts and data you are authorized to access.

## License

MIT.
