# ChatGPT web contract

These are private web-application endpoints, not a public OpenAI compatibility promise. They can change at any time. ChatGPT-Export treats schema drift as an explicit failure rather than guessing.

| Purpose | Method / path |
| --- | --- |
| Workspace/account discovery | `GET /backend-api/accounts/check/v4-2023-04-27` |
| Main history | `GET /backend-api/conversations?offset=...&limit=...&order=updated` |
| Archived history | same endpoint with `is_archived=true` |
| Project index | `GET /backend-api/gizmos/snorlax/sidebar?conversations_per_gizmo=0...` |
| Project conversation chain | `GET /backend-api/gizmos/<project>/conversations?cursor=...` |
| Conversation detail | `GET /backend-api/conversation/<conversation>` |
| Shared inventory | `GET /backend-api/shared_conversations?...` |
| Shared detail | `GET /backend-api/share/<share>` |
| Memories | `GET /backend-api/memories?include_memory_entries=true` |
| Custom instructions | `GET /backend-api/user_system_messages` |
| Settings | `GET /backend-api/settings` |
| Beta feature settings | `GET /backend-api/settings/beta_features` |
| File resolver | `GET /backend-api/files/download/<file>?conversation_id=...` or `?gizmo_id=...` |
| Custom GPT inventory | `GET /public-api/gizmos/discovery/mine?...` |

Authenticated requests set both `Authorization: Bearer ...` and `X-Authorization: Bearer ...`. When exporting a specific workspace they also set `ChatGPT-Account-Id`.

## Drift policy

When a contract changes:

1. do not broaden the client into arbitrary URL fetching;
2. preserve the failed run and sanitized evidence;
3. reproduce the new shape using synthetic fixtures;
4. update the smallest adapter necessary;
5. run unit/CI checks;
6. only then resume real exports.
