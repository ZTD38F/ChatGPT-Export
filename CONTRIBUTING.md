# Contributing

Changes should preserve the project's reliability contract.

Before opening a pull request:

```bash
npm run check
npm test
bash -n install.sh update.sh uninstall.sh scripts/chatgpt-exportctl
```

Provider endpoint changes require:

1. a narrow explanation of observed drift;
2. synthetic tests or fixtures where practical;
3. no arbitrary-fetch fallback;
4. no destructive ChatGPT operations;
5. no credentials, private conversation data, signed URLs or account identifiers in commits.

A provider failure should become a visible `partial`/`auth_required` state, not silent data loss.
