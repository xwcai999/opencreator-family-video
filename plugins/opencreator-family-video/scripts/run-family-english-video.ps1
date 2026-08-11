[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$TeachingGoal,
    [Parameter(Mandatory = $true)][string]$Scene,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Action = 'Perform each dialogue action naturally in order.',
    [ValidateSet('Preschool', 'A1')][string]$Difficulty = 'Preschool',
    [string[]]$Vocabulary = @(),
    [string[]]$Participants = @('father', 'mother', 'child'),
    [ValidateSet('480p', '720p')][string]$Resolution = '480p',
    [ValidateRange(1, 2)][int]$MaxAttempts = 1,
    [ValidateRange(30, 7200)][int]$TimeoutSeconds = 900,
    [string]$CandidatePath,
    [string]$VideoRoot,
    [string]$GrokExecutable,
    [string]$GrokSessionRoot,
    [switch]$RegenerateDialogue,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$ScriptRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $ScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($VideoRoot)) { $VideoRoot = Join-Path $RepoRoot 'video-output' }
if ([string]::IsNullOrWhiteSpace($GrokExecutable)) { $GrokExecutable = 'grok' }
if ([string]::IsNullOrWhiteSpace($GrokSessionRoot)) { $GrokSessionRoot = Join-Path $env:USERPROFILE '.grok\sessions' }
$VideoRoot = [IO.Path]::GetFullPath($VideoRoot).TrimEnd('\', '/')

function Resolve-OutputDirectory {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOf([char]0) -ge 0 -or
        $Value -match '^[~]' -or $Value -match '\$env:|\$\{|%[^%]+%' -or
        $Value -match '^(\\\\|\\\\[?.]\\)' -or $Value -match '[*?\[\]]') {
        throw 'OutputDirectory 不允许为空、变量、UNC/设备路径或通配符。'
    }
    $full = if ([IO.Path]::IsPathRooted($Value)) { [IO.Path]::GetFullPath($Value) }
        else { [IO.Path]::GetFullPath((Join-Path $VideoRoot $Value)) }
    if ($full.Equals($VideoRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $full.StartsWith(($VideoRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "OutputDirectory 必须位于 $VideoRoot 的子目录。"
    }
    return $full.TrimEnd('\', '/')
}

function Resolve-CandidatePath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -match '^[~]' -or $Value -match '\$env:|\$\{|%[^%]+%' -or
        $Value -match '^(\\\\|\\\\[?.]\\)' -or $Value -match '[*?\[\]]') {
        throw 'CandidatePath 不允许变量、UNC/设备路径或通配符。'
    }
    $full = [IO.Path]::GetFullPath($Value)
    if (-not $full.StartsWith(($VideoRoot + '\'), [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "CandidatePath 必须是 $VideoRoot 内存在的文件。"
    }
    return $full
}

function Invoke-ChildScript {
    param([string]$ScriptPath, [string[]]$Arguments, [string]$FailureMessage)
    & pwsh -NoProfile -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage（exit=$LASTEXITCODE）。" }
}

try {
    New-Item -ItemType Directory -Path $VideoRoot -Force | Out-Null
    $outputPath = Resolve-OutputDirectory -Value $OutputDirectory
    $dialoguePlanPath = Join-Path $outputPath 'dialogue-plan.json'
    $generator = Join-Path $ScriptRoot 'generate-family-dialogue.ps1'
    $runner = Join-Path $ScriptRoot 'run-grok-family-video.ps1'
    if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) { throw "脚本生成器不存在：$generator" }
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "视频执行器不存在：$runner" }

    $candidate = Resolve-CandidatePath -Value $CandidatePath
    if ($RegenerateDialogue -or -not (Test-Path -LiteralPath $dialoguePlanPath -PathType Leaf)) {
        $args = @('-Title', $Title, '-TeachingGoal', $TeachingGoal, '-Scene', $Scene,
            '-OutputPath', $dialoguePlanPath, '-Difficulty', $Difficulty,
            '-Vocabulary', (@($Vocabulary) -join ','), '-Participants', (@($Participants) -join ','),
            '-VideoRoot', $VideoRoot)
        if ($candidate) { $args += @('-CandidatePath', $candidate) }
        Invoke-ChildScript -ScriptPath $generator -Arguments $args -FailureMessage '教学微情景生成失败'
    }

    $runnerArgs = @('-Title', $Title, '-Scene', $Scene, '-Action', $Action,
        '-OutputDirectory', $outputPath, '-DialogueMode', 'MicroScene',
        '-DialoguePath', $dialoguePlanPath, '-Participants', (@($Participants) -join ','),
        '-Resolution', $Resolution, '-MaxAttempts', [string]$MaxAttempts,
        '-TimeoutSeconds', [string]$TimeoutSeconds, '-VideoRoot', $VideoRoot,
        '-GrokExecutable', $GrokExecutable, '-GrokSessionRoot', $GrokSessionRoot)
    if ($PrepareOnly) { $runnerArgs += '-PrepareOnly' }
    Invoke-ChildScript -ScriptPath $runner -Arguments $runnerArgs -FailureMessage 'Grok 家庭英语视频流水线失败'
} catch {
    [Console]::Error.WriteLine("run-family-english-video 失败：$($_.Exception.Message)")
    exit 1
}
