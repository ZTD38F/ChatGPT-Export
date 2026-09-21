# Operational security

## Session credential

`https://chatgpt.com/api/auth/session` normally contains a bearer access token. Anyone who can use that token may be able to read data exposed to the same ChatGPT account until the token expires. Treat the complete JSON as a password-equivalent secret.

ChatGPT-Export:

- accepts the session only through the admin-authenticated local control API;
- never prints session JSON or bearer values;
- encrypts the stored session with Fernet;
- stores the encryption key separately in `/etc/chatgpt-export/fernet.key`, root-owned with mode `0640` and group access restricted to the dedicated service account;
- stores the random UI admin token separately, root-owned with mode `0640` and group access restricted to the dedicated service account;
- does not forward the ChatGPT bearer token to signed file-download hosts.

## Network exposure

Default bind: `127.0.0.1:8788`.

Do not change this to `0.0.0.0` just to make the UI reachable. Prefer an authenticated HTTPS reverse proxy, VPN, SSH tunnel, or equivalent private ingress. TLS alone is not enough if the page is publicly accessible: the admin token is a high-value credential.

## SSRF controls

ChatGPT file resolver endpoints may return signed external HTTPS URLs. The downloader:

- accepts HTTPS only;
- rejects embedded URL credentials;
- resolves the hostname before download;
- rejects loopback, private, link-local, multicast, reserved and unspecified addresses;
- validates every redirect destination before following it;
- ignores ambient HTTP proxy environment variables for provider and asset requests;
- streams assets to restricted temporary files instead of buffering entire large files in RAM;
- enforces a maximum asset size;
- never copies the ChatGPT Authorization header to the asset host.

## Logs

Normal application logs intentionally avoid request bodies, authorization headers and provider response bodies. Error messages include status and bounded diagnostic metadata only.

Do not enable generic reverse-proxy request-body logging on the `/api/session` endpoint.

## Read-only provider surface

The provider adapter has no method for deleting, editing, renaming, archiving, sharing or mutating ChatGPT content. If a future feature needs a write operation, it must be a separate explicitly reviewed capability and must not be smuggled into the backup adapter.
