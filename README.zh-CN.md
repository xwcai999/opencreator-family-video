# OpenCreator Family Video（中文说明）

[English](README.md)

本仓库提供 Codex 插件与安全的视频工作流，负责约束对白、路径、角色合同和
验收证据。它不提供 Grok、模型、ASR 服务、ffmpeg、凭据、真实角色图或成片。

## 重要限制

- 克隆仓库后不能零配置端到端生成视频。
- 需要使用者自行安装并登录 Grok CLI/Build，配置 OAuth、hooks、PowerShell 7、
  Node、ffmpeg/ffprobe，并自行提供 `OPENCODE_GO_API_KEY` 与 `ARK_API_KEY`。
- 本仓库包含参数化的 ASR 客户端与离线合同自检；它会在你明确配置 `ARK_API_KEY`
  后把本地音轨上传到火山引擎，绝不伪造字幕。实时服务、账户和授权仍由使用者负责。
- 真实媒体、角色图片、音轨、ASR 原始响应、manifest、日志、会话缓存和浏览器配置
  必须留在本地，并且需要独立确认模型服务与素材授权。

## OpenCreator 生态

本项目属于 [OpenCreator](https://github.com/xwcai999/opencreator) 生态，兄弟项目包括 [OpenCreator Novel](https://github.com/xwcai999/opencreator-novel)、[OpenCreator Music](https://github.com/xwcai999/opencreator-music) 和 [OpenCreator Dashboard](https://github.com/xwcai999/opencreator-dashboard)。各仓库保持独立安装与独立版本。

## 离线验证

```powershell
pwsh -NoProfile -File .\plugins\opencreator-family-video\tests\test-family-dialogue-generator.ps1
pwsh -NoProfile -File .\plugins\opencreator-family-video\tests\test-path-contract.ps1
node .\plugins\opencreator-family-video\scripts\transcribe-agentplan-asr.mjs --self-test
```

代码采用 Apache-2.0；可选 `ws` 依赖保持 MIT，见 `THIRD_PARTY_NOTICES.md`。
