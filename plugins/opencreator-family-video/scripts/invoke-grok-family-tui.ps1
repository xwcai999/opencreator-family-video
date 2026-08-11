[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PromptPath,
    [string]$VideoRoot,
    [string]$GrokExecutable,
    [string]$GrokSessionRoot,
    [string]$MediaStateRoot,
    [string]$TaskOutput
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($VideoRoot)) { $VideoRoot = Join-Path $repoRoot 'video-output' }
if ([string]::IsNullOrWhiteSpace($GrokExecutable)) { $GrokExecutable = 'grok' }
if ([string]::IsNullOrWhiteSpace($GrokSessionRoot)) { $GrokSessionRoot = Join-Path $env:USERPROFILE '.grok\sessions' }
$VideoRoot = [IO.Path]::GetFullPath($VideoRoot).TrimEnd('\', '/')
$fullPromptPath = [IO.Path]::GetFullPath($PromptPath)
if (-not $fullPromptPath.StartsWith(($VideoRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Grok 提示文件必须位于 VideoRoot 内。' }
if (-not (Test-Path -LiteralPath $fullPromptPath -PathType Leaf)) { throw "Grok 提示文件不存在：$fullPromptPath" }
if (-not (Get-Command $GrokExecutable -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $GrokExecutable -PathType Leaf)) { throw "Grok CLI 不存在：$GrokExecutable" }
$prompt = Get-Content -LiteralPath $fullPromptPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Grok 提示文件为空。' }
$outputDirectory = if ($TaskOutput) { [IO.Path]::GetFullPath($TaskOutput) } else { [IO.Path]::GetDirectoryName($fullPromptPath) }
if (-not $outputDirectory.StartsWith(($VideoRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'TaskOutput 必须位于 VideoRoot 内。' }
if ([string]::IsNullOrWhiteSpace($MediaStateRoot)) { $MediaStateRoot = Join-Path $VideoRoot '.grok-media-budget' }
$debugPath = Join-Path $outputDirectory 'grok-debug.log'
$transcriptPath = Join-Path $outputDirectory 'grok-launcher-transcript.txt'
$guardRules = @"
这是视频专用会话。所有用户素材和最终产物只能位于 $VideoRoot。
禁止读取、搜索、编辑或列出其他业务目录，禁止运行任意终端命令。
需要列目录、建目录、复制、下载、哈希或媒体探测时，只能调用本仓库的 grok-video-io.ps1。
复制当前 Grok 会话媒体时必须传入来源路径中的 SessionId 和 SessionCwd。
路径必须使用单引号包围的绝对路径，不能使用变量、管道、重定向或命令拼接。
"@

$env:GROK_VIDEO_ONLY_ROOT = $VideoRoot
$env:GROK_VIDEO_MEDIA_BUDGET = 'strict-v1'
$env:GROK_VIDEO_MEDIA_STATE_ROOT = $MediaStateRoot
$env:GROK_VIDEO_TASK_OUTPUT = $outputDirectory
$env:GROK_VIDEO_SESSION_ROOT = $GrokSessionRoot
New-Item -ItemType Directory -Path $outputDirectory,$MediaStateRoot -Force | Out-Null
Set-Location -LiteralPath $VideoRoot
try {
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    & $GrokExecutable --debug --debug-file $debugPath --no-alt-screen --always-approve --cwd $VideoRoot --rules $guardRules $prompt
    $code = $LASTEXITCODE
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
exit $code
