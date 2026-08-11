# OpenCreator Family Video

[简体中文](README.zh-CN.md)

OpenCreator Family Video is a Codex plugin and an auditable workflow for 10-second bilingual family-English scenes:

`teaching goal → constrained dialogue → external video generation → ASR of actual audio → exact/semantic review → bilingual subtitles`

## What is included

- parameterized PowerShell orchestration;
- guarded dialogue generation and candidate-file handling;
- Grok session launcher and media path controls;
- a Volcengine ASR client and semantic-review step;
- deterministic media, subtitle, hash, and state checks;
- sanitized fixtures and offline contract tests.

The repository does not ship credentials, model weights, reference images, rendered media, browser profiles, production manifests, or session logs.

## Prerequisites

- PowerShell 7, Node.js, ffmpeg, and ffprobe;
- an installed and authenticated Grok CLI/Build with the required video session hooks;
- `OPENCODE_GO_API_KEY` for dialogue and semantic review;
- `ARK_API_KEY` for Volcengine ASR;
- rights to every input image, audio file, and generated output.

A clone cannot run end to end without this local provider setup. The ASR step uploads the extracted audio to the configured provider only when the user runs the full workflow with its credential present.

## Use

The Skill is at `plugins/opencreator-family-video/skills/grok-family-english-video/SKILL.md`. All media and candidate files must stay below an explicit `-VideoRoot`.

```powershell
pwsh -NoProfile -File .\plugins\opencreator-family-video\scripts\run-family-english-video.ps1 `
  -Title "Breakfast helper" `
  -TeachingGoal "Ask politely and help with breakfast" `
  -Scene "A bright family kitchen" `
  -OutputDirectory ".\breakfast" `
  -VideoRoot (Resolve-Path .\video-output).Path `
  -PrepareOnly
```

The scripts reject candidate files outside the video root, UNC/device paths, wildcard or environment expansion, and link/reparse traversal. Full generation also enforces the configured media-call budget and never treats preset dialogue as the actual audio transcript.

## OpenCreator ecosystem

This project is part of [OpenCreator](https://github.com/xwcai999/opencreator), alongside [OpenCreator Novel](https://github.com/xwcai999/opencreator-novel), [OpenCreator Music](https://github.com/xwcai999/opencreator-music), and [OpenCreator Dashboard](https://github.com/xwcai999/opencreator-dashboard). Each repository remains independently installable and versioned.

## Offline validation

```powershell
pwsh -NoProfile -File .\plugins\opencreator-family-video\tests\test-family-dialogue-generator.ps1
pwsh -NoProfile -File .\plugins\opencreator-family-video\tests\test-path-contract.ps1
node .\plugins\opencreator-family-video\scripts\transcribe-agentplan-asr.mjs --self-test
```

These commands do not call Grok, a text model, or ASR.

Read [MODEL_AND_MEDIA_RIGHTS.md](MODEL_AND_MEDIA_RIGHTS.md), [SECURITY.md](SECURITY.md), [PRIVACY.md](PRIVACY.md), [TERMS.md](TERMS.md), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) before connecting a provider or publishing media.

Code is Apache-2.0. The vendored `ws` runtime remains MIT licensed. This project is not affiliated with or endorsed by OpenAI, xAI, ByteDance, or the named providers.
