# Troubleshooting

## Service does not start

```bash
sudo chatgpt-exportctl status
sudo chatgpt-exportctl logs 200
sudo chatgpt-exportctl doctor
```

The installer itself performs a live health check and transactional rollback if a newly installed release cannot remain healthy. It restores the previous release symlink, protected config files, control CLI and service definition.

## `AUTH_REQUIRED`

The imported ChatGPT access token expired or was rejected (normally HTTP 401). Open `https://chatgpt.com/api/auth/session` in a signed-in browser again and paste the fresh JSON. New sessions are preflight-checked before they are encrypted and stored. Already verified unchanged conversations remain resumable.

## `PARTIAL`

Open the latest validation report:

```bash
sudo cat /var/lib/chatgpt-export/data/latest-validation.json
```

Look at `scope_errors`, `artifact_errors`, `conversation_errors`, `shared_errors`, and `asset_errors`. `PARTIAL` is intentionally conservative.

## 429 / rate limit

The provider client shares one cooldown across workers and respects `Retry-After`. Do not increase concurrency aggressively. Default concurrency is 4 and the accepted configuration range is 1–10.

## Project conversation missing

Project conversations are inventoried independently from the main history endpoint. The final membership file for a conversation records all scopes in which it was discovered. If a Project chain itself fails, the run cannot be `COMPLETE`.

## File failed but chat succeeded

A conversation's raw graph can still be archived while an old signed resource is unavailable. This produces an asset error and therefore a `PARTIAL` run. The raw file descriptor remains in the conversation payload for future recovery attempts.

## Reverse proxy

The application intentionally does not install Caddy/nginx automatically because public DNS, certificates and authentication are deployment-specific. Keep it on loopback until your proxy is ready. Preserve `X-Admin-Token`, disable request-body logging for `/api/session`, and use HTTPS.
