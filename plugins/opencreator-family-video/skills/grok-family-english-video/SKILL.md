---
name: grok-family-english-video
description: 使用固定角色合同、实际音轨 ASR 和安全路径门禁编排 10 秒儿童情景英语双语短视频。Use when Codex needs to prepare, generate, resume, or verify a guarded family-English video task；依赖外部 Grok CLI、OpenCode Go 和火山引擎 ASR，不能零配置运行。
---

# OpenCreator 亲子情景英语视频

只编排仓库中的参数化流水线；不要在 Skill 中绕过路径守卫、媒体预算、ASR
或语义门禁，也不要把 provider 凭据、真实角色图或成片写入仓库。

## 唯一入口

```powershell
pwsh -NoProfile -File <repo>\plugins\opencreator-family-video\scripts\run-family-english-video.ps1 <参数>
```

必须显式传入 `-VideoRoot`。相对输出目录会解析到该根目录下；候选对白、输入
媒体和所有产物不得离开该根目录。脚本拒绝变量、UNC/设备路径、通配符和链接。

## 外部前置

- PowerShell 7、Node、ffmpeg、ffprobe；
- Grok CLI/Build、OAuth 登录态和其会话 hooks；
- `OPENCODE_GO_API_KEY`（对白/语义）和 `ARK_API_KEY`（ASR）；
- 各 provider 与输入媒体的再分发授权。

仓库只提供代码和脱敏 fixtures，克隆后不能零配置端到端运行。

## 固定合同

- 10 秒、9:16，默认 480p；
- 一次 `image_edit`，随后一次 `image_to_video`；不允许 `image_gen`、额外变体或自动重试；
- 对白由 `deepseek-v4-flash` 生成候选，实际英文必须来自 ASR；
- exact 对齐失败时才允许受限语义复核；失败不能伪装成成功；
- 角色合同只引用本地占位文件，真实参考图必须由使用者另行提供并确认权利。

## 产物与验收

成功产物应包含 `最终成片.mp4`、`manifest.json`、ASR 结果和双语 ASS；验收
必须证明时长约 10 秒、一个主视频流、至少一个音频流，且最终音频流哈希与原视频一致。

## 隐私边界

不要读取或上传视频根之外的媒体、歌曲、小说、凭据、浏览器缓存或无关项目。
不要向用户展示 API key、session ID、trace ID 或 provider 原始响应。
