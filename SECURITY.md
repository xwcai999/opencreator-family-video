# Security policy / 安全策略

## 不要提交的内容

- API keys, OAuth tokens, cookies, auth files, browser profiles or session caches;
- real videos, audio, role images, screenshots, ASR responses or provider logs;
- manifests containing request IDs, trace IDs, session IDs, hashes or private paths;
- data outside the configured video root.

## 报告问题

请不要在公开 issue 中粘贴凭据或原始媒体。通过 GitHub Security Advisory
报告可复现的路径越界、密钥泄露或媒体预算绕过问题，并附上最小脱敏夹具。

The public package is not a replacement for provider security controls. Keep
Grok hooks, OAuth state and credentials outside the repository.
