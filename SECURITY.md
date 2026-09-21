# Security policy

Do not open a public GitHub issue containing a ChatGPT session token, bearer token, private export content, signed asset URL, reverse-proxy credential, private server address, SSH key, or production environment file.

The following must never be committed:

- `/api/auth/session` responses;
- `accessToken` values;
- ChatGPT cookies;
- `/etc/chatgpt-export/*`;
- `/var/lib/chatgpt-export/*`;
- generated export archives;
- reverse-proxy private keys.

See `docs/SECURITY.md` for the operational threat model.
