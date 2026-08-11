[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,

    [string]$TargetEnglish,

    [string]$ChineseMeaning,

    [Parameter(Mandatory = $true)]
    [string]$Scene,

    [Parameter(Mandatory = $true)]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [ValidateSet('MicroScene', 'SingleLine')]
    [string]$DialogueMode = 'MicroScene',

    [string]$DialoguePath,

    [Alias('DialogueJson')]
    [string]$Dialogue,

    [string[]]$Participants = @('father', 'mother', 'child'),

    [ValidateSet('480p', '720p')]
    [string]$Resolution = '480p',

    [ValidateRange(1, 2)]
    [int]$MaxAttempts = 1,

    [ValidateRange(1, 7200)]
    [int]$TimeoutSeconds = 900,

    [string]$SemanticReviewPath,

    [string]$WorkspaceRoot,

    [string]$VideoRoot,

    [string]$RoleRoot,

    [string]$GrokExecutable,

    [string]$GrokSessionRoot,

    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$ScriptRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $ScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = $RepoRoot }
if ([string]::IsNullOrWhiteSpace($VideoRoot)) { $VideoRoot = Join-Path $WorkspaceRoot 'video-output' }
if ([string]::IsNullOrWhiteSpace($RoleRoot)) { $RoleRoot = Join-Path $VideoRoot '角色库\亲子英语家庭-v1' }
if ([string]::IsNullOrWhiteSpace($GrokExecutable)) { $GrokExecutable = 'grok' }
if ([string]::IsNullOrWhiteSpace($GrokSessionRoot)) { $GrokSessionRoot = $GrokSessionRoot }
$VideoRoot = [IO.Path]::GetFullPath($VideoRoot).TrimEnd('\', '/')
$RoleRoot = [IO.Path]::GetFullPath($RoleRoot).TrimEnd('\', '/')
if (-not $RoleRoot.StartsWith(($VideoRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw "RoleRoot 必须位于 $VideoRoot 内。" }
$CharacterManifestPath = Join-Path $RoleRoot 'characters.json'
$TranscriberPath = Join-Path $ScriptRoot 'transcribe-agentplan-asr.mjs'
$SemanticReviewerPath = Join-Path $ScriptRoot 'review-family-dialogue-semantic.ps1'
$GrokTuiLauncherPath = Join-Path $ScriptRoot 'invoke-grok-family-tui.ps1'

$Manifest = $null
$ManifestPath = $null
$OutputPath = $null
$TaskId = $null
$RequestFingerprint = $null
$RawVideoPath = $null
$FinalVideoPath = $null
$ResumeRawVideo = $false
$ExistingGrokSessionId = $null
$SemanticReviewResolvedPath = $null

function Get-UtcNowString {
    return [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "目标目录不存在：$parent"
    }
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 30
    Write-Utf8File -Path $Path -Content ($json + [Environment]::NewLine)
}

function Test-ReparseFreePath {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$AllowedRoot
    )

    $relative = [IO.Path]::GetRelativePath($AllowedRoot, $FullPath)
    if ($relative -eq '.') { return $true }
    $cursor = $AllowedRoot
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { break }
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
    }
    return $true
}

function Resolve-VideoOutputDirectory {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'OutputDirectory 不能为空。' }
    if ($Value.IndexOf([char]0) -ge 0) { throw 'OutputDirectory 含有空字符。' }
    if ($Value -match '^[~]' -or $Value -match '\$env:|\$\{|%[^%]+%' -or
        $Value -match '^(\\\\|\\\\[?.]\\)' -or $Value -match '[*?\[\]]') {
        throw 'OutputDirectory 不允许变量、UNC/设备路径或通配符。'
    }
    foreach ($segment in ($Value -split '[\\/]')) {
        if ($segment -notin @('', '.', '..') -and $segment -match '[ .]$') {
            throw 'OutputDirectory 路径段不能以点或空格结尾。'
        }
    }

    $full = if ([IO.Path]::IsPathRooted($Value)) {
        [IO.Path]::GetFullPath($Value)
    } else {
        [IO.Path]::GetFullPath((Join-Path $VideoRoot $Value))
    }
    $root = [IO.Path]::GetFullPath($VideoRoot).TrimEnd('\', '/')
    $prefix = $root + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "输出目录必须位于 $root 内。"
    }
    if ($full.Equals($RoleRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith(([IO.Path]::GetFullPath($RoleRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw '输出目录不能位于固定角色库内。'
    }
    if (-not (Test-ReparseFreePath -FullPath $full -AllowedRoot $root)) {
        throw '输出目录路径包含链接或联接点。'
    }
    New-Item -ItemType Directory -Path $full -Force | Out-Null
    if (-not (Test-ReparseFreePath -FullPath $full -AllowedRoot $root)) {
        throw '创建后的输出目录包含链接或联接点。'
    }
    return $full.TrimEnd('\', '/')
}

function Assert-SafeText {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [switch]$SingleLine
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name 不能为空。" }
    if ($Value.IndexOf([char]0) -ge 0) { throw "$Name 含有空字符。" }
    if ($SingleLine -and $Value -match '[\r\n]') { throw "$Name 必须是单行文本。" }
    return $Value.Trim()
}

function Get-ParticipantTokens {
    param([string[]]$Values)

    $allowed = @('father', 'mother', 'child')
    $tokens = [Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        foreach ($token in ([string]$value -split '[,;]')) {
            $name = $token.Trim().ToLowerInvariant()
            if (-not $name) { continue }
            if ($name -notin $allowed) {
                throw "Participants 只允许 father、mother、child；收到：$name"
            }

            if (-not $tokens.Contains($name)) { $tokens.Add($name) }
        }
    }
    if ($tokens.Count -eq 0) { throw 'Participants 不能为空。' }
    return @($tokens)
}

function Resolve-DialogueInputPath {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'DialoguePath 不能为空。' }
    if ($Value.IndexOf([char]0) -ge 0 -or $Value -match '^[~]' -or
        $Value -match '\$env:|\$\{|%[^%]+%' -or $Value -match '^(\\\\|\\\\[?.]\\)' -or
        $Value -match '[*?\[\]]') {
        throw 'DialoguePath 不允许变量、UNC/设备路径或通配符。'
    }
    $full = if ([IO.Path]::IsPathRooted($Value)) {
        [IO.Path]::GetFullPath($Value)
    } else {
        [IO.Path]::GetFullPath((Join-Path $VideoRoot $Value))
    }
    # 对白会进入 Grok prompt，只允许来自视频工作区，避免把歌曲/小说等
    # 其他业务目录内容带入外部模型上下文。
    $root = [IO.Path]::GetFullPath($VideoRoot).TrimEnd('\', '/')
    $prefix = $root + '\'
    if (-not ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw "DialoguePath 必须位于 $root 内。"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "DialoguePath 不存在：$full" }
    if (-not (Test-ReparseFreePath -FullPath $full -AllowedRoot $root)) { throw 'DialoguePath 路径包含链接或联接点。' }
    return $full
}

function Resolve-SemanticReviewPath {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'SemanticReviewPath 不能为空。' }
    if ($Value.IndexOf([char]0) -ge 0 -or $Value -match '^[~]' -or
        $Value -match '\$env:|\$\{|%[^%]+%' -or $Value -match '^(\\\\|\\\\[?.]\\)' -or
        $Value -match '[*?\[\]]') {
        throw 'SemanticReviewPath 不允许变量、UNC/设备路径或通配符。'
    }
    $full = if ([IO.Path]::IsPathRooted($Value)) {
        [IO.Path]::GetFullPath($Value)
    } else {
        [IO.Path]::GetFullPath((Join-Path $VideoRoot $Value))
    }
    $root = [IO.Path]::GetFullPath($VideoRoot).TrimEnd('\', '/')
    $prefix = $root + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SemanticReviewPath 必须位于 $root 内。"
    }
    if ([IO.Path]::GetExtension($full) -ine '.json') { throw 'SemanticReviewPath 必须是 .json 文件。' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "SemanticReviewPath 不存在：$full" }
    if (-not (Test-ReparseFreePath -FullPath $full -AllowedRoot $root)) { throw 'SemanticReviewPath 路径包含链接或联接点。' }
    return $full
}

function Get-DialogueProperty {
    param([Parameter(Mandatory = $true)][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-DialogueContract {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('MicroScene', 'SingleLine')][string]$Mode,
        [string]$Path,
        [string]$Json,
        [Parameter(Mandatory = $true)][string[]]$ParticipantNames,
        [string]$LegacyEnglish,
        [string]$LegacyChinese,
        [Parameter(Mandatory = $true)][string]$LegacyAction
    )

    if ($Mode -eq 'SingleLine') {
        if (-not [string]::IsNullOrWhiteSpace($Path) -or -not [string]::IsNullOrWhiteSpace($Json)) {
            throw 'SingleLine 模式不能同时提供 DialoguePath/DialogueJson。'
        }
        $english = Assert-SafeText -Name 'TargetEnglish' -Value $LegacyEnglish -SingleLine
        $chinese = Assert-SafeText -Name 'ChineseMeaning' -Value $LegacyChinese -SingleLine
        $action = Assert-SafeText -Name 'Action' -Value $LegacyAction -SingleLine
        return [pscustomobject]@{
            mode = 'SingleLine'
            source = 'legacy_fields'
            source_model = 'debug-single-line'
            total_words = ([Regex]::Matches($english, "[A-Za-z0-9]+(?:['’\-][A-Za-z0-9]+)?")).Count
            entries = @([ordered]@{
                speaker = $ParticipantNames[0]
                english = $english
                chinese = $chinese
                action = $action
                start_hint_ms = 0
                end_hint_ms = 10000
            })
        }
    }

    if ([string]::IsNullOrWhiteSpace($Path) -and [string]::IsNullOrWhiteSpace($Json)) {
        throw 'MicroScene 模式必须提供 DialoguePath 或 DialogueJson；不会把旧单句静默扩写。'
    }
    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not [string]::IsNullOrWhiteSpace($Json)) {
        throw 'DialoguePath 与 DialogueJson 只能二选一。'
    }
    $source = if (-not [string]::IsNullOrWhiteSpace($Path)) { Resolve-DialogueInputPath -Value $Path } else { 'inline' }
    try {
        $raw = if ($source -eq 'inline') { $Json } else { Get-Content -LiteralPath $source -Raw -Encoding UTF8 }
        $parsed = $raw | ConvertFrom-Json -Depth 20
    } catch {
        throw "对白 JSON 无法解析：$($_.Exception.Message)"
    }
    if ($parsed -is [Collections.IEnumerable] -and $parsed -isnot [string]) {
        throw 'MicroScene 对白 JSON 必须是带 source_model/model 和 dialogue 数组的 envelope，禁止裸数组冒充生成器来源。'
    }
    $providedModel = Get-DialogueProperty -Object $parsed -Name 'source_model'
    if ($null -eq $providedModel) { $providedModel = Get-DialogueProperty -Object $parsed -Name 'model' }
    if ($null -eq $providedModel) { $providedModel = Get-DialogueProperty -Object $parsed -Name 'dialogue_source_model' }
    if ([string]::IsNullOrWhiteSpace([string]$providedModel)) {
        throw 'MicroScene 对白 envelope 缺少 source_model/model。'
    }
    $sourceModel = ([string]$providedModel).Trim()
    if ($sourceModel -ne 'deepseek-v4-flash') { throw "MicroScene 对白 source_model 必须固定为 deepseek-v4-flash；实际 $sourceModel" }
    $candidate = Get-DialogueProperty -Object $parsed -Name 'dialogue'
    if ($null -eq $candidate) { $candidate = Get-DialogueProperty -Object $parsed -Name 'lines' }
    if ($null -eq $candidate) { throw '对白 JSON envelope 缺少 dialogue/lines 数组。' }
    $items = @($candidate)
    if ($items.Count -lt 3 -or $items.Count -gt 4) {
        throw "MicroScene 必须包含 3-4 轮对白；实际 $($items.Count) 轮。"
    }

    $entries = [Collections.Generic.List[object]]::new()
    $previousEnd = -1L
    $totalWords = 0
    foreach ($item in $items) {
        if ($null -eq $item) { throw '对白条目不能为 null。' }
        $speaker = ([string](Get-DialogueProperty -Object $item -Name 'speaker')).Trim().ToLowerInvariant()
        if ($speaker -notin $ParticipantNames) { throw "对白 speaker '$speaker' 不在 Participants 中。" }
        $english = Assert-SafeText -Name 'dialogue.english' -Value ([string](Get-DialogueProperty -Object $item -Name 'english')) -SingleLine
        $chinese = Assert-SafeText -Name 'dialogue.chinese' -Value ([string](Get-DialogueProperty -Object $item -Name 'chinese')) -SingleLine
        $action = Assert-SafeText -Name 'dialogue.action' -Value ([string](Get-DialogueProperty -Object $item -Name 'action')) -SingleLine
        $startRaw = Get-DialogueProperty -Object $item -Name 'start_hint_ms'
        $endRaw = Get-DialogueProperty -Object $item -Name 'end_hint_ms'
        $start = 0L
        $end = 0L
        if ($null -eq $startRaw -or -not [long]::TryParse([string]$startRaw, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$start)) {
            throw 'dialogue.start_hint_ms 必须是整数。'
        }
        if ($null -eq $endRaw -or -not [long]::TryParse([string]$endRaw, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$end)) {
            throw 'dialogue.end_hint_ms 必须是整数。'
        }
        if ($start -lt 0 -or $end -gt 10000 -or $end -le $start) { throw '对白时间窗必须满足 0 <= start < end <= 10000。' }
        if ($start -lt $previousEnd) { throw '对白时间窗必须按顺序递增且不可倒序。' }
        $wordCount = ([Regex]::Matches($english, "[A-Za-z0-9]+(?:['’\-][A-Za-z0-9]+)?")).Count
        if ($wordCount -lt 1 -or $wordCount -gt 8) { throw '每轮英文对白必须为 1-8 个词。' }
        $totalWords += $wordCount
        $entries.Add([ordered]@{
            speaker = $speaker
            english = $english
            chinese = $chinese
            action = $action
            start_hint_ms = $start
            end_hint_ms = $end
        })
        $previousEnd = $end
    }
    if ($totalWords -lt 14 -or $totalWords -gt 22) { throw "MicroScene 英文总词数必须为 14-22；实际 $totalWords。" }
    return [pscustomobject]@{ mode = 'MicroScene'; source = $source; source_model = $sourceModel; total_words = $totalWords; entries = @($entries) }
}

function Assert-RoleContract {
    if (-not (Test-Path -LiteralPath $CharacterManifestPath -PathType Leaf)) {
        if ($PrepareOnly) {
            $placeholder = [ordered]@{}
            foreach ($key in @('family_master', 'father', 'mother', 'child')) {
                $placeholder[$key] = [ordered]@{ file = 'characters.example.json'; path = $CharacterManifestPath; sha256 = 'placeholder'; identity = $null; wardrobe = $null }
            }
            return [pscustomobject]@{ manifest_path = $CharacterManifestPath; references = [pscustomobject]$placeholder; source_sha256 = 'placeholder' }
        }
        throw "固定角色契约缺失：$CharacterManifestPath"
    }
    if (-not (Test-ReparseFreePath -FullPath $CharacterManifestPath -AllowedRoot $VideoRoot)) {
        throw '固定角色契约路径包含链接或联接点。'
    }

    try {

        $characters = Get-Content -LiteralPath $CharacterManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30
    } catch {
        throw "固定角色契约不是有效 JSON：$($_.Exception.Message)"
    }
    if ([string]$characters.status -ne 'active') { throw '固定角色契约不是 active 状态。' }
    if ($null -eq $characters.references) { throw '固定角色契约缺少 references。' }

    $expected = [ordered]@{
        family_master = 'family-master.png'
        father = 'father.png'
        mother = 'mother.png'
        child = 'child.png'
    }
    $verified = [ordered]@{}
    foreach ($key in $expected.Keys) {
        $entry = $characters.references.PSObject.Properties[$key]
        if ($null -eq $entry -or $null -eq $entry.Value) {
            throw "固定角色契约缺少 references.$key。"
        }
        $fileName = [string]$entry.Value.file
        $declaredHash = ([string]$entry.Value.sha256).Trim().ToLowerInvariant()
        if ($fileName -ne $expected[$key]) {
            throw "references.$key 必须固定引用 $($expected[$key])。"
        }
        if ($declaredHash -notmatch '^[0-9a-f]{64}$') {
            throw "references.$key.sha256 不是 SHA-256。"
        }
        $path = Join-Path $RoleRoot $expected[$key]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            if ($PrepareOnly) {
                $verified[$key] = [ordered]@{ file = $expected[$key]; path = $path; sha256 = 'placeholder'; identity = $null; wardrobe = $null }
                continue
            }
            throw "角色参考图缺失：$path"
        }
        if (-not (Test-ReparseFreePath -FullPath $path -AllowedRoot $VideoRoot)) {
            throw "角色参考图路径包含链接或联接点：$path"
        }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $declaredHash) {
            throw "角色参考图哈希不匹配：$($expected[$key])"
        }
        $verified[$key] = [ordered]@{
            file = $expected[$key]
            path = $path
            sha256 = $actualHash
            identity = if ($entry.Value.identity) { [string]$entry.Value.identity } else { $null }
            wardrobe = if ($entry.Value.wardrobe) { [string]$entry.Value.wardrobe } else { $null }
        }
    }
    return [pscustomobject]@{
        manifest_path = $CharacterManifestPath
        references = [pscustomobject]$verified
        source_sha256 = (Get-FileHash -LiteralPath $CharacterManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Normalize-English {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $text = $Value.ToLowerInvariant().Replace([char]0x2019, "'").Replace([char]0x2018, "'")
    # 删除撇号，使 “let's” 与 ASR 的 “lets” 等常见归一化结果等价。
    $text = $text.Replace("'", '')
    $text = [Regex]::Replace($text, '[^a-z0-9]+', ' ')
    return ([Regex]::Replace($text, '\s+', ' ')).Trim()
}

function Get-AsrDialogueAlignment {
    param(
        [Parameter(Mandatory = $true)][object]$Asr,
        [Parameter(Mandatory = $true)][object[]]$ExpectedEntries,
        [Parameter(Mandatory = $true)][ValidateSet('MicroScene', 'SingleLine')][string]$Mode
    )

    $asrText = [string]$Asr.result.text
    $normalizedAsr = Normalize-English -Value $asrText
    if ([string]::IsNullOrWhiteSpace($normalizedAsr)) { throw 'ASR 未返回可校验的英文文本。' }
    $utterances = @($Asr.result.utterances | Where-Object { $_ -and [string]$_.text })
    $segments = [Collections.Generic.List[object]]::new()
    $segmentOffset = 0
    foreach ($utterance in $utterances) {
        $normalizedSegment = Normalize-English -Value ([string]$utterance.text)
        if (-not $normalizedSegment) { continue }
        $segmentStart = $segmentOffset
        $segmentEnd = $segmentStart + $normalizedSegment.Length
        $segments.Add([pscustomobject]@{
            text = $normalizedSegment
            start_offset = $segmentStart
            end_offset = $segmentEnd
            start_ms = if ($utterance.start_ms -is [ValueType]) { [double]$utterance.start_ms } else { $null }
            end_ms = if ($utterance.end_ms -is [ValueType]) { [double]$utterance.end_ms } else { $null }
        })
        $segmentOffset = $segmentEnd + 1
    }

    $cursor = 0
    $alignmentEntries = [Collections.Generic.List[object]]::new()
    $evidence = [Collections.Generic.List[object]]::new()
    foreach ($expected in $ExpectedEntries) {
        $expectedText = Normalize-English -Value ([string]$expected.english)
        if (-not $expectedText) { throw '对白英文归一化后为空。' }
        $matchIndex = $normalizedAsr.IndexOf($expectedText, $cursor, [StringComparison]::OrdinalIgnoreCase)
        if ($matchIndex -lt 0) {
            throw "ASR 缺少或打乱对白：$($expected.english)"
        }
        $unmatched = if ($matchIndex -gt $cursor) { $normalizedAsr.Substring($cursor, $matchIndex - $cursor).Trim() } else { '' }
        if ($Mode -eq 'MicroScene' -and $unmatched) {
            throw "ASR 包含未声明的额外可辨识对白：$unmatched"
        }
        $matchEnd = $matchIndex + $expectedText.Length
        $matchedSegments = @($segments | Where-Object { $_.end_offset -gt $matchIndex -and $_.start_offset -lt $matchEnd })
        $startMs = [double]$expected.start_hint_ms
        $endMs = [double]$expected.end_hint_ms
        if ($matchedSegments.Count -gt 0) {
            $withStart = @($matchedSegments | Where-Object { $null -ne $_.start_ms })
            $withEnd = @($matchedSegments | Where-Object { $null -ne $_.end_ms })
            if ($withStart.Count -gt 0) { $startMs = [Math]::Max(0, [double]$withStart[0].start_ms) }
            if ($withEnd.Count -gt 0) { $endMs = [Math]::Max($startMs + 250, [double]$withEnd[-1].end_ms) }
        }
        $alignmentEntries.Add([ordered]@{
            speaker = $expected.speaker
            english = $expected.english
            chinese = $expected.chinese
            action = $expected.action
            start_ms = [Math]::Round($startMs, 0)
            end_ms = [Math]::Round($endMs, 0)
        })
        $evidence.Add([ordered]@{
            expected = $expected.english
            normalized = $expectedText
            match_start = $matchIndex
            match_end = $matchEnd
            asr_start_ms = [Math]::Round($startMs, 0)
            asr_end_ms = [Math]::Round($endMs, 0)
            extra_before = $unmatched
        })
        $cursor = $matchEnd
    }
    if ($Mode -eq 'MicroScene') {
        $trailing = if ($cursor -lt $normalizedAsr.Length) { $normalizedAsr.Substring($cursor).Trim() } else { '' }
        if ($trailing) { throw "ASR 包含未声明的额外可辨识对白：$trailing" }
    }
    return [pscustomobject]@{
        text = $asrText
        entries = @($alignmentEntries)
        evidence = @($evidence)
        normalized_text = $normalizedAsr
    }
}

function Get-ProviderTimedDialogueAlignment {
    param(
        [Parameter(Mandatory = $true)][object]$MatchEvidence,
        [Parameter(Mandatory = $true)][object[]]$ApprovedEntries,
        [Parameter(Mandatory = $true)][double]$VideoDurationSeconds
    )

    $lineMatchesProperty = $MatchEvidence.PSObject.Properties['line_matches']
    if ($null -eq $lineMatchesProperty) { throw 'MicroScene ASR match_evidence 缺少 line_matches。' }
    $lineMatches = @($lineMatchesProperty.Value)
    if ($lineMatches.Count -ne $ApprovedEntries.Count) {
        throw "MicroScene ASR line_matches 数量不符：期望 $($ApprovedEntries.Count)，实际 $($lineMatches.Count)。"
    }
    $maxMs = [Math]::Ceiling($VideoDurationSeconds * 1000.0)
    $previousExpectedIndex = $null
    $previousActualIndex = -1L
    $timedEntries = [Collections.Generic.List[object]]::new()
    foreach ($index in 0..($ApprovedEntries.Count - 1)) {
        $match = $lineMatches[$index]
        $expectedRaw = $match.PSObject.Properties['expected_index']
        if ($null -eq $expectedRaw) { $expectedRaw = $match.PSObject.Properties['line_index'] }
        $expectedIndex = 0L
        if ($null -eq $expectedRaw -or -not [long]::TryParse([string]$expectedRaw.Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$expectedIndex) -or
            ($null -ne $previousExpectedIndex -and $expectedIndex -le $previousExpectedIndex)) {
            throw "MicroScene ASR expected_index 乱序：第 $($index + 1) 轮。"
        }
        $actualRaw = $match.PSObject.Properties['actual_segment_index']
        $actualIndex = 0L
        if ($null -eq $actualRaw -or -not [long]::TryParse([string]$actualRaw.Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$actualIndex) -or $actualIndex -le $previousActualIndex) {
            throw "MicroScene ASR actual_segment_index 不是严格递增：第 $($index + 1) 轮。"
        }
        $matchedProperty = $match.PSObject.Properties['matched']
        if ($null -ne $matchedProperty -and ([string]$matchedProperty.Value -notmatch '^(?i:true|1)$')) {
            throw "MicroScene ASR 第 $($index + 1) 轮未匹配。"

        }
        $startProperty = $match.PSObject.Properties['start_ms']
        $endProperty = $match.PSObject.Properties['end_ms']
        $startMs = 0.0
        $endMs = 0.0
        if ($null -eq $startProperty -or -not [double]::TryParse([string]$startProperty.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$startMs)) {
            throw "MicroScene ASR 第 $($index + 1) 轮缺少 start_ms。"
        }
        if ($null -eq $endProperty -or -not [double]::TryParse([string]$endProperty.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$endMs)) {
            throw "MicroScene ASR 第 $($index + 1) 轮缺少 end_ms。"
        }
        if ($startMs -lt 0 -or $endMs -le $startMs -or $endMs -gt $maxMs) {
            throw "MicroScene ASR 第 $($index + 1) 轮时间窗越界或无效：$startMs-$endMs ms（视频 $maxMs ms）。"
        }
        $approved = $ApprovedEntries[$index]
        $expectedEnglishProperty = $match.PSObject.Properties['expected_english']
        if ($null -ne $expectedEnglishProperty -and
            (Normalize-English -Value ([string]$expectedEnglishProperty.Value)) -ne (Normalize-English -Value ([string]$approved.english))) {
            throw "MicroScene ASR 第 $($index + 1) 轮 expected_english 未绑定已批准对白。"
        }
        $timedEntries.Add([ordered]@{
            speaker = $approved.speaker
            english = $approved.english
            chinese = $approved.chinese
            action = $approved.action
            start_ms = [Math]::Round($startMs, 0)
            end_ms = [Math]::Round($endMs, 0)
        })
        $previousExpectedIndex = $expectedIndex
        $previousActualIndex = $actualIndex
    }
    return @($timedEntries)
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Escape-AssText {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $text = $Value -replace '[\r\n]+', ' '
    $text = $text.Replace('{', '\{').Replace('}', '\}')
    return $text.Trim()
}

function Convert-MillisecondsToAssTime {
    param([double]$Milliseconds)
    if ($Milliseconds -lt 0) { $Milliseconds = 0 }
    $totalCentiseconds = [Math]::Round($Milliseconds / 10, 0, [MidpointRounding]::AwayFromZero)
    $hours = [Math]::Floor($totalCentiseconds / 360000)
    $minutes = [Math]::Floor(($totalCentiseconds % 360000) / 6000)
    $seconds = [Math]::Floor(($totalCentiseconds % 6000) / 100)
    $centiseconds = $totalCentiseconds % 100
    return ('{0}:{1:00}:{2:00}.{3:00}' -f $hours, $minutes, $seconds, $centiseconds)
}

function Write-Manifest {
    param([Parameter(Mandatory = $true)][object]$Value)
    if ($null -eq $script:ManifestPath) { throw 'manifest 路径尚未初始化。' }
    Write-JsonFile -Path $script:ManifestPath -Value $Value
}

function Set-ManifestStatus {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('planned', 'running', 'generated', 'transcribed', 'subtitled', 'verified', 'verified_semantic', 'failed')][string]$Status,
        [string]$Reason = ''
    )
    if ($null -eq $script:Manifest) { return }
    $script:Manifest.status = $Status
    $script:Manifest.updated_at = Get-UtcNowString
    if ($Reason) {
        $script:Manifest.failure = [ordered]@{ message = $Reason }
    }
    if ($null -eq $script:Manifest.status_history) {
        $script:Manifest.status_history = [Collections.Generic.List[object]]::new()
    }
    $script:Manifest.status_history.Add([ordered]@{ status = $Status; at = $script:Manifest.updated_at })
    Write-Manifest -Value $script:Manifest
}

function Get-ExistingSessionIds {
    $sessionRoot = $GrokSessionRoot
    $encodedCwd = [uri]::EscapeDataString([IO.Path]::GetFullPath($VideoRoot).TrimEnd('\', '/'))
    $cwdRoot = Join-Path $sessionRoot $encodedCwd
    if (-not (Test-Path -LiteralPath $cwdRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $cwdRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' } |
        Select-Object -ExpandProperty Name)
}

function Get-GrokSessionRoot {
    $sessionRoot = $GrokSessionRoot
    $encodedCwd = [uri]::EscapeDataString([IO.Path]::GetFullPath($VideoRoot).TrimEnd('\', '/'))
    return Join-Path $sessionRoot $encodedCwd
}

function Get-CompletedFailedTurn {
    param([string[]]$BeforeSessionIds)
    $root = Get-GrokSessionRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $sessions = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $BeforeSessionIds } | Sort-Object LastWriteTime)
    foreach ($session in $sessions) {
        $eventsPath = Join-Path $session.FullName 'events.jsonl'
        if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) { continue }
        $eventsTail = (Get-Content -LiteralPath $eventsPath -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
        if ($eventsTail -notmatch '"type"\s*:\s*"turn_ended"') { continue }
        $summaryText = ''
        $summaryPath = Join-Path $session.FullName 'summary.json'
        if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
            try {
                $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
                $summaryText = [string]$summary.last_turn_summary
            } catch { }
        }
        $signalsPath = Join-Path $session.FullName 'signals.json'
        $toolFailures = $null
        if (Test-Path -LiteralPath $signalsPath -PathType Leaf) {
            try {
                $signals = Get-Content -LiteralPath $signalsPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
                $toolFailures = $signals.toolFailureCount
            } catch { }
        }
        return [pscustomobject]@{ session_id = $session.Name; summary = $summaryText; tool_failures = $toolFailures }
    }
    return $null
}

function Stop-ProcessTree {
    param([AllowNull()][Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            try { $Process.Kill($true) } catch { $Process.Kill() }
            $Process.WaitForExit(5000)
        }
    } catch { }
}

function Invoke-GrokGeneration {
    param(
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$VideoPath,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $attemptStarted = [DateTime]::UtcNow
    $before = if (Test-Path -LiteralPath $VideoPath -PathType Leaf) {
        $old = Get-Item -LiteralPath $VideoPath -Force
        [pscustomobject]@{ length = $old.Length; write_utc = $old.LastWriteTimeUtc }
    } else { $null }
    $beforeSessions = @(Get-ExistingSessionIds)
    $process = $null
    $generated = $false
    $exitCode = $null
    try {
        # Grok TUI 的 embedded agent 需要真实控制台。独立 PowerShell 窗口直接调用
        # 交互初始 PROMPT；父脚本只监控固定产物并在完成后终止整棵进程树。
        $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$GrokTuiLauncherPath`" -PromptPath `"$PromptFile`" -VideoRoot `"$VideoRoot`" -GrokExecutable `"$GrokExecutable`" -GrokSessionRoot `"$GrokSessionRoot`" -MediaStateRoot `"$(Join-Path $VideoRoot '.grok-media-budget')`" -TaskOutput `"$OutputPath`""
        $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -WorkingDirectory $VideoRoot `
            -WindowStyle Normal -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
        $stableLength = $null
        $stableSince = $null
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $VideoPath -PathType Leaf) {
                $item = Get-Item -LiteralPath $VideoPath -Force
                $isNew = $null -eq $before -or $item.Length -ne $before.length -or $item.LastWriteTimeUtc -gt $attemptStarted
                if ($isNew -and $item.Length -gt 1024) {
                    if ($stableLength -eq $item.Length) {
                        if ($null -eq $stableSince) { $stableSince = [DateTime]::UtcNow }
                        if (([DateTime]::UtcNow - $stableSince).TotalSeconds -ge 2) {
                            $generated = $true

                            break
                        }
                    } else {
                        $stableLength = $item.Length
                        $stableSince = $null
                    }
                }
            }
            if ($process.HasExited) {
                $exitCode = $process.ExitCode
                break
            }
            if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
                $failedTurn = Get-CompletedFailedTurn -BeforeSessionIds $beforeSessions
                if ($null -ne $failedTurn) {
                    Stop-ProcessTree -Process $process
                    $detail = if ($failedTurn.summary) { $failedTurn.summary } else { 'Grok 回合结束但没有生成固定视频文件。' }
                    throw "Grok 回合失败（session=$($failedTurn.session_id), tool_failures=$($failedTurn.tool_failures)）：$detail"
                }
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $generated -and -not $process.HasExited -and [DateTime]::UtcNow -ge $deadline) {
            Stop-ProcessTree -Process $process
            throw "Grok 生成超时（${Timeout}s），已终止进程。"
        }
        if (-not $generated) {
            if (Test-Path -LiteralPath $VideoPath -PathType Leaf) {
                $item = Get-Item -LiteralPath $VideoPath -Force
                $isNew = $null -eq $before -or $item.Length -ne $before.length -or $item.LastWriteTimeUtc -gt $attemptStarted
                if ($isNew -and $item.Length -gt 1024) { $generated = $true }
            }
        }
        if (-not $generated) {
            $code = if ($null -eq $exitCode) { 'unknown' } else { [string]$exitCode }
            throw "Grok 未在固定路径生成原视频.mp4（进程退出码：$code）。"
        }
        $afterSessions = @(Get-ExistingSessionIds)
        $newSessions = @($afterSessions | Where-Object { $_ -notin $beforeSessions })
        $sessionId = if ($newSessions.Count -gt 0) { $newSessions[-1] } else { $null }
        return [pscustomobject]@{ session_id = $sessionId; exit_code = $exitCode; started_at = $attemptStarted.ToString('o'); generated = $true }
    } finally {
        if ($null -ne $process) {
            # 文件稳定后立刻停止 TUI，防止模型继续产生第二个变体或再次调用视频工具。
            Stop-ProcessTree -Process $process
        }
    }
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (($output | ForEach-Object { [string]$_ }) -join ' ').Trim()
        if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
        if ($detail) { throw "$FailureMessage（$detail）" }
        throw "$FailureMessage（退出码 $exitCode）"
    }
    return $output
}

function Assert-FileExists {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Description)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Description 不存在：$Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -le 0) { throw "$Description 为空：$Path" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Description 不能是链接：$Path" }
}

function Get-AgentPlanApiKey {
    if (-not [string]::IsNullOrWhiteSpace($env:ARK_API_KEY)) { return $env:ARK_API_KEY.Trim() }
    try {
        $userKey = [string](Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name 'ARK_API_KEY' -ErrorAction Stop).ARK_API_KEY
    } catch {
        $userKey = ''
    }
    if ([string]::IsNullOrWhiteSpace($userKey)) { throw '缺少用户级 ARK_API_KEY，拒绝开始生成。' }
    $env:ARK_API_KEY = $userKey.Trim()
    return $env:ARK_API_KEY
}

function Get-MediaProbe {
    param(
        [Parameter(Mandatory = $true)][string]$ProbeExecutable,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $lines = Invoke-NativeChecked -FilePath $ProbeExecutable -Arguments @(
        '-v', 'error', '-show_entries',
        'format=duration,size,format_name:stream=index,codec_type,codec_name,width,height,sample_rate,channels,avg_frame_rate',
        '-of', 'json', '--', $Path
    ) -FailureMessage "媒体检查失败：$Path"
    try { return (($lines -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20) }
    catch { throw "ffprobe 返回无效 JSON：$Path" }
}

function Assert-TenSecondAvVideo {
    param(
        [Parameter(Mandatory = $true)][object]$Probe,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $duration = 0.0
    if (-not [double]::TryParse([string]$Probe.format.duration, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)) {
        throw "$Description 缺少有效时长。"
    }
    if ($duration -lt 9.5 -or $duration -gt 10.6) {
        throw "$Description 时长不是允许的10秒编码范围：$duration 秒。"
    }
    $movingVideoStreams = @($Probe.streams | Where-Object {
        $_.codec_type -eq 'video' -and [string]$_.avg_frame_rate -notin @('', '0/0')
    })
    if ($movingVideoStreams.Count -ne 1) {
        throw "$Description 必须且只能包含一个动态主视频流。"
    }
    if (@($Probe.streams | Where-Object { $_.codec_type -eq 'audio' }).Count -lt 1) {
        throw "$Description 缺少原声音频流。"
    }
    return $duration
}

function Get-AudioStreamSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$FfmpegExecutable,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $lines = Invoke-NativeChecked -FilePath $FfmpegExecutable -Arguments @(
        '-v', 'error', '-i', $Path, '-map', '0:a:0', '-c', 'copy', '-f', 'streamhash', '-hash', 'sha256', '-'
    ) -FailureMessage "音频流哈希失败：$Path"
    $text = ($lines -join [Environment]::NewLine)
    $match = [Regex]::Match($text, '(?i)SHA256=([0-9a-f]{64})')
    if (-not $match.Success) { throw "无法解析音频流哈希：$Path" }
    return $match.Groups[1].Value.ToLowerInvariant()
}

try {
    $Title = Assert-SafeText -Name 'Title' -Value $Title -SingleLine
    $Scene = Assert-SafeText -Name 'Scene' -Value $Scene -SingleLine
    $Action = Assert-SafeText -Name 'Action' -Value $Action -SingleLine
    $participantTokens = Get-ParticipantTokens -Values $Participants
    $dialogueContract = Get-DialogueContract -Mode $DialogueMode -Path $DialoguePath -Json $Dialogue `
        -ParticipantNames $participantTokens -LegacyEnglish $TargetEnglish -LegacyChinese $ChineseMeaning -LegacyAction $Action
    if ($SemanticReviewPath) { $SemanticReviewResolvedPath = Resolve-SemanticReviewPath -Value $SemanticReviewPath }
    $dialogueEntries = @($dialogueContract.entries)
    if ($DialogueMode -eq 'SingleLine') {
        $TargetEnglish = [string]$dialogueEntries[0].english
        $ChineseMeaning = [string]$dialogueEntries[0].chinese
    } else {
        # MicroScene 的目标句由结构化对白负责；保留旧字段但不把它们当作隐式单句。
        $TargetEnglish = if ([string]::IsNullOrWhiteSpace($TargetEnglish)) { $null } else { Assert-SafeText -Name 'TargetEnglish' -Value $TargetEnglish -SingleLine }
        $ChineseMeaning = if ([string]::IsNullOrWhiteSpace($ChineseMeaning)) { $null } else { Assert-SafeText -Name 'ChineseMeaning' -Value $ChineseMeaning -SingleLine }
    }
    $OutputPath = Resolve-VideoOutputDirectory -Value $OutputDirectory
    $roleContract = Assert-RoleContract

    $RawVideoPath = Join-Path $OutputPath '原视频.mp4'
    $FinalVideoPath = Join-Path $OutputPath '最终成片.mp4'
    $framePath = Join-Path $OutputPath '首帧.jpg'
    $audioPath = Join-Path $OutputPath '原始音轨.wav'
    $asrPath = Join-Path $OutputPath '原始音轨_识别结果.json'
    $dialoguePathForAsr = Join-Path $OutputPath 'dialogue.json'
    $semanticReviewOutputPath = Join-Path $OutputPath 'semantic-review.json'
    $assPath = Join-Path $OutputPath '单句英中.ass'
    $requestPath = Join-Path $OutputPath 'request.json'
    $promptPath = Join-Path $OutputPath 'prompt.txt'
    $ManifestPath = Join-Path $OutputPath 'manifest.json'

    $roleRefList = [Collections.Generic.List[object]]::new()
    foreach ($participant in $participantTokens) {
        $roleRefList.Add($roleContract.references.$participant)
    }
    # image_edit 最多使用三张清晰参考。三人同框时直接使用三张个人母版；
    # 一至两人场景再补 family_master，用于保留家庭关系与身高感。
    if ($participantTokens.Count -lt 3) {
        $roleRefList.Add($roleContract.references.family_master)

    }
    $roleRefLines = foreach ($reference in $roleRefList) {
        $identity = if ($reference.identity) { "；固定特征：$($reference.identity)" } else { '' }
        $wardrobe = if ($reference.wardrobe) { "；固定服装：$($reference.wardrobe)" } else { '' }
        "- $($reference.path)（SHA-256=$($reference.sha256)$identity$wardrobe）"
    }
    $roleRefLines = @($roleRefLines)

    $requestCore = [ordered]@{
        schema_version = 1
        kind = 'grok-family-video'
        title = $Title
        target_english = $TargetEnglish
        chinese_meaning = $ChineseMeaning
        scene = $Scene
        action = $Action
        participants = @($participantTokens)
        dialogue_mode = $dialogueContract.mode
        dialogue_source = $dialogueContract.source
        dialogue_source_model = $dialogueContract.source_model
        source_model = $dialogueContract.source_model
        dialogue_total_words = $dialogueContract.total_words
        dialogue = @($dialogueEntries)
        resolution = $Resolution
        aspect_ratio = '9:16'
        duration_seconds = 10
        max_attempts = $MaxAttempts
        timeout_seconds = $TimeoutSeconds
        output_directory = $OutputPath
        role_contract = [ordered]@{
            manifest = $CharacterManifestPath
            manifest_sha256 = $roleContract.source_sha256
            references = [ordered]@{}
        }
    }
    foreach ($key in @('family_master', 'father', 'mother', 'child')) {
        $requestCore.role_contract.references[$key] = [ordered]@{
            file = $roleContract.references.$key.file
            sha256 = $roleContract.references.$key.sha256
        }
    }
    $requestCore.character_references = $requestCore.role_contract.references
    $requestJsonForHash = $requestCore | ConvertTo-Json -Depth 30 -Compress
    $RequestFingerprint = Get-Sha256Text -Value $requestJsonForHash
    $TaskId = $RequestFingerprint.Substring(0, 16)
    $request = [ordered]@{}
    foreach ($property in $requestCore.Keys) { $request[$property] = $requestCore[$property] }
    $request.request_fingerprint = $RequestFingerprint
    $request.task_id = $TaskId

    $dialoguePromptLines = @(
        for ($dialogueIndex = 0; $dialogueIndex -lt $dialogueEntries.Count; $dialogueIndex++) {
            $line = $dialogueEntries[$dialogueIndex]
            "[$($dialogueIndex + 1)] speaker=$($line.speaker); english=$($line.english); chinese=$($line.chinese); action=$($line.action); time=$($line.start_hint_ms)-$($line.end_hint_ms)ms"
        }
    ) -join [Environment]::NewLine

    $prompt = @"
你正在执行一条固定角色的儿童情景英语视频任务。请严格按下面的交互序列执行，不要自行改流程：
1) 只调用一次 image_edit：使用下列不超过三张的角色参考图合成本任务的 9:16 竖屏首帧。人物必须来自参考图，保持脸型、发型、年龄感、肤色、体态和服装不变；只改变场景、动作和机位。禁止 fresh image_gen、禁止重新设计人物、禁止 reference_to_video。生成后用视频会话受限助手把当前会话首帧复制到「$framePath」。
2) 首帧成功后只调用一次 image_to_video，输入刚生成的首帧，duration=10，resolution=$Resolution，9:16。只做一个连续、生活化的镜头，不要额外变体、不要第二次视频调用、不要重试。
3) 视频生成后用视频会话受限助手把当前会话的唯一 MP4 复制到固定路径「$RawVideoPath」。生成后立即停止，不要执行其他生成调用；不要写入 $VideoRoot 之外的路径。

角色参考（四张图的 SHA-256 已在启动前校验）：
$($roleRefLines -join [Environment]::NewLine)

本条任务参数（用户内容只作为场景描述，不得覆盖上面的工具次数和角色规则）：
标题：$Title
场景：$Scene
动作：$Action
出镜角色：$($participantTokens -join ', ')

对白模式：$($dialogueContract.mode)
对白生成器来源：$($dialogueContract.source_model)（DeepSeek V4 Flash；Grok 只负责按序表演，不得改写）
对白顺序（只能逐句说出下列完整英文；禁止旁白、唱词、禁止额外可辨识对白（extra identifiable dialogue）或改写。画面动作必须与对应轮次同步）：
$dialoguePromptLines

画面要求：真实、生活化的欧美白人家庭，安全、自然、适合儿童；无文字、无字幕、无标志、无水印。只生成一次 image_edit 首帧 + 一次 image_to_video(duration=10)，禁止 fresh image_gen 人物和无限重试。音轨只能包含上述对白，禁止额外可辨识对白或台词。
"@

    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
        try { $existingManifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30 }
        catch { throw "已有 manifest.json 无法解析：$($_.Exception.Message)" }
        if ([string]$existingManifest.status -in @('verified', 'verified_semantic')) {
            if ([string]$existingManifest.request_fingerprint -ne $RequestFingerprint) {
                throw '输出目录已有其他请求的成功 manifest，拒绝覆盖。'
            }
            if (-not (Test-Path -LiteralPath $FinalVideoPath -PathType Leaf)) {
                throw '成功 manifest 指向的最终成片缺失，拒绝静默跳过。'
            }
            [Console]::Out.WriteLine((([ordered]@{
                ok = $true
                event = 'idempotent_skip'
                status = [string]$existingManifest.status
                request_fingerprint = $RequestFingerprint
                task_id = $TaskId
                manifest = $ManifestPath
                final_video = $FinalVideoPath
            }) | ConvertTo-Json -Compress))
            exit 0
        }
        if ([string]$existingManifest.status -eq 'running') {
            throw '输出目录已有 running 任务，拒绝并发运行。'
        }
        if ([string]$existingManifest.status -eq 'failed' -and
            [string]$existingManifest.request_fingerprint -eq $RequestFingerprint -and
            (Test-Path -LiteralPath $RawVideoPath -PathType Leaf)) {
            $ResumeRawVideo = $true
            $ExistingGrokSessionId = [string]$existingManifest.grok_session_id
        }
    }

    Write-JsonFile -Path $requestPath -Value $request
    Write-Utf8File -Path $promptPath -Content $prompt
    $Manifest = [ordered]@{
        schema_version = 1
        task_id = $TaskId
        request_fingerprint = $RequestFingerprint
        status = 'planned'
        created_at = Get-UtcNowString
        updated_at = Get-UtcNowString
        request_file = $requestPath
        prompt_file = $promptPath
        output_directory = $OutputPath
        role_contract = $request.role_contract
        character_references = $request.character_references
        dialogue_mode = $dialogueContract.mode
        dialogue_source = $dialogueContract.source
        dialogue_source_model = $dialogueContract.source_model
        source_model = $dialogueContract.source_model
        dialogue = @($dialogueEntries)
        fixed = [ordered]@{ aspect_ratio = '9:16'; duration_seconds = 10; resolution = $Resolution }
        artifacts = [ordered]@{
            frame = $framePath
            raw_video = $RawVideoPath
            audio_wav = $audioPath
            asr_json = $asrPath
            dialogue_json = $dialoguePathForAsr
            semantic_review = $semanticReviewOutputPath
            subtitle_ass = $assPath
            final_video = $FinalVideoPath
        }
        attempts = [Collections.Generic.List[object]]::new()
        status_history = [Collections.Generic.List[object]]::new()
        grok_session_id = $null
        failure = $null
    }
    $Manifest.status_history.Add([ordered]@{ status = 'planned'; at = $Manifest.created_at })
    Write-Manifest -Value $Manifest

    if ($PrepareOnly) {
        [Console]::Out.WriteLine((([ordered]@{
            ok = $true
            event = 'prepared'
            status = 'planned'
            task_id = $TaskId
            request_fingerprint = $RequestFingerprint
            request = $requestPath
            prompt = $promptPath
            manifest = $ManifestPath
        }) | ConvertTo-Json -Compress))
        exit 0
    }

    if (-not (Get-Command $GrokExecutable -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath $GrokExecutable -PathType Leaf)) { throw "Grok 可执行文件不存在：$GrokExecutable" }
    if (-not (Test-Path -LiteralPath $GrokTuiLauncherPath -PathType Leaf)) { throw "Grok TUI 启动器不存在：$GrokTuiLauncherPath" }
    $ffmpegCommand = Get-Command ffmpeg -ErrorAction Stop
    $ffprobeCommand = Get-Command ffprobe -ErrorAction Stop
    $nodeCommand = Get-Command node -ErrorAction Stop
    $pwshCommand = Get-Command pwsh -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $TranscriberPath -PathType Leaf)) { throw "ASR 脚本不存在：$TranscriberPath" }
    if (-not (Test-Path -LiteralPath $SemanticReviewerPath -PathType Leaf)) { throw "语义审查脚本不存在：$SemanticReviewerPath" }
    $null = Get-AgentPlanApiKey
    $env:GROK_VIDEO_ONLY_ROOT = $VideoRoot

    Set-ManifestStatus -Status 'running'
    $generation = $null
    $generated = $false
    if ($ResumeRawVideo) {
        Assert-FileExists -Path $RawVideoPath -Description '可恢复原视频'

        $Manifest.grok_session_id = $ExistingGrokSessionId
        $Manifest.attempts.Add([ordered]@{
            index = 0
            status = 'reused_existing_video'
            started_at = Get-UtcNowString
            ended_at = Get-UtcNowString
            session_id = $ExistingGrokSessionId
            process_exit_code = $null
        })
        $generated = $true
        Write-Manifest -Value $Manifest
    } else {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $attemptRecord = [ordered]@{ index = $attempt; status = 'running'; started_at = Get-UtcNowString; ended_at = $null; session_id = $null; process_exit_code = $null }
            $Manifest.attempts.Add($attemptRecord)
            Write-Manifest -Value $Manifest
            try {
                $generation = Invoke-GrokGeneration -PromptFile $promptPath -VideoPath $RawVideoPath -Attempt $attempt -Timeout $TimeoutSeconds
                $attemptRecord.status = 'generated'
                $attemptRecord.ended_at = Get-UtcNowString
                $attemptRecord.session_id = $generation.session_id
                $attemptRecord.process_exit_code = $generation.exit_code
                $Manifest.grok_session_id = $generation.session_id
                $generated = $true
                break
            } catch {
                $attemptRecord.status = 'failed'
                $attemptRecord.ended_at = Get-UtcNowString
                $attemptRecord.error = $_.Exception.Message
                Write-Manifest -Value $Manifest
                if ($attempt -ge $MaxAttempts) { throw }
            }
        }
    }
    if (-not $generated) { throw '未生成原视频。' }
    Assert-FileExists -Path $RawVideoPath -Description '原视频'
    # ffprobe 只做确定性存在/容器检查；不修改源 MP4。
    $rawProbe = Get-MediaProbe -ProbeExecutable $ffprobeCommand.Source -Path $RawVideoPath
    $rawDuration = Assert-TenSecondAvVideo -Probe $rawProbe -Description '原视频'
    Set-ManifestStatus -Status 'generated'

    # 真实模式才落盘独立对白 JSON；PrepareOnly 契约只写 request/prompt/manifest。
    Write-JsonFile -Path $dialoguePathForAsr -Value ([ordered]@{
        dialogue_mode = $dialogueContract.mode
        source_model = $dialogueContract.source_model
        dialogue = @($dialogueEntries)
    })
    Invoke-NativeChecked -FilePath $ffmpegCommand.Source -Arguments @('-y', '-i', $RawVideoPath, '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', $audioPath) -FailureMessage 'FFmpeg 提取原始音轨失败' | Out-Null
    Assert-FileExists -Path $audioPath -Description '原始音轨 WAV'
    Invoke-NativeChecked -FilePath $nodeCommand.Source -Arguments @($TranscriberPath, $audioPath, $asrPath, $dialoguePathForAsr) -FailureMessage 'Agent Plan ASR 失败' | Out-Null
    Assert-FileExists -Path $asrPath -Description 'ASR 结果'
    $asr = Get-Content -LiteralPath $asrPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30
    $providerMatchEvidence = $asr.result.match_evidence
    $verificationStatus = 'verified'
    $exactFailure = $null
    try {
        $localAlignment = Get-AsrDialogueAlignment -Asr $asr -ExpectedEntries $dialogueEntries -Mode $dialogueContract.mode
        $alignment = $localAlignment
        if ($dialogueContract.mode -eq 'MicroScene') {
            if ($null -eq $providerMatchEvidence) { throw 'MicroScene ASR 缺少 match_evidence。' }
            $providerAllProperty = $providerMatchEvidence.PSObject.Properties['all_matched']
            if ($null -eq $providerAllProperty -or ([string]$providerAllProperty.Value -notmatch '^(?i:true|1)$')) {
                throw 'Agent Plan ASR match_evidence 判定对白未全部匹配。'
            }
            $providerTimedEntries = Get-ProviderTimedDialogueAlignment -MatchEvidence $providerMatchEvidence `
                -ApprovedEntries $dialogueEntries -VideoDurationSeconds $rawDuration
            $alignment = [pscustomobject]@{
                normalized_text = $localAlignment.normalized_text
                entries = @($providerTimedEntries)
                evidence = @($providerMatchEvidence.line_matches)
            }
        }
    } catch {
        if ($dialogueContract.mode -ne 'MicroScene') { throw }
        $exactFailure = $_.Exception.Message
        $reviewArguments = @(
            '-NoProfile', '-NonInteractive', '-File', $SemanticReviewerPath,
            '-ExpectedPath', $dialoguePathForAsr, '-AsrPath', $asrPath, '-OutputPath', $semanticReviewOutputPath,
            '-VideoRoot', $VideoRoot
        )
        if ($SemanticReviewResolvedPath) { $reviewArguments += @('-CandidatePath', $SemanticReviewResolvedPath) }
        Invoke-NativeChecked -FilePath $pwshCommand.Source -Arguments $reviewArguments -FailureMessage 'Agent Plan 实际对白语义审查失败' | Out-Null
        Assert-FileExists -Path $semanticReviewOutputPath -Description '实际对白语义审查结果'
        $semanticReview = Get-Content -LiteralPath $semanticReviewOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30
        if ($semanticReview.pass -ne $true -or [string]$semanticReview.source_model -ne 'deepseek-v4-flash') {
            throw '实际对白未通过语义验收。'
        }
        $semanticEntries = @($semanticReview.subtitle_lines)
        if ($semanticEntries.Count -lt 1) { throw '语义验收没有返回实际对白字幕。' }
        $alignment = [pscustomobject]@{
            normalized_text = ((@($semanticEntries) | ForEach-Object { [string]$_.english }) -join ' ')
            entries = $semanticEntries
            evidence = @($semanticEntries | ForEach-Object {
                [ordered]@{ segment_indices = @($_.segment_indices); english = $_.english; start_ms = $_.start_ms; end_ms = $_.end_ms }
            })
        }
        $verificationStatus = 'verified_semantic'
        $Manifest.semantic_review = $semanticReview
    }
    $Manifest.asr_alignment = [ordered]@{
        normalized_text = $alignment.normalized_text
        match_evidence = @($alignment.evidence)
        provider_match_evidence = $providerMatchEvidence
        exact_failure = $exactFailure
        verification_mode = if ($verificationStatus -eq 'verified') { 'exact' } else { 'semantic' }
    }
    Set-ManifestStatus -Status 'transcribed'

    $subtitleLines = foreach ($line in $alignment.entries) {
        "Dialogue: 0,$(Convert-MillisecondsToAssTime -Milliseconds $line.start_ms),$(Convert-MillisecondsToAssTime -Milliseconds $line.end_ms),Default,,0,0,72,,$(Escape-AssText -Value $line.english)\N$(Escape-AssText -Value $line.chinese)"
    }
    $ass = @"
[Script Info]
ScriptType: v4.00+
PlayResX: 480
PlayResY: 854
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Microsoft YaHei,34,&H00FFFFFF,&H00FFFFFF,&H00181818,&H80181818,0,0,1,3,1,2,24,24,72,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
$($subtitleLines -join [Environment]::NewLine)
"@
    Write-Utf8File -Path $assPath -Content $ass
    Set-ManifestStatus -Status 'subtitled'

    $subtitleFilterPath = $assPath.Replace('\', '/').Replace(':', '\:').Replace("'", "\'")
    Invoke-NativeChecked -FilePath $ffmpegCommand.Source -Arguments @('-y', '-i', $RawVideoPath, '-vf', "ass='$subtitleFilterPath'", '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-c:a', 'copy', '-movflags', '+faststart', $FinalVideoPath) -FailureMessage 'FFmpeg 双语字幕合成失败' | Out-Null
    Assert-FileExists -Path $FinalVideoPath -Description '最终成片'
    $finalProbe = Get-MediaProbe -ProbeExecutable $ffprobeCommand.Source -Path $FinalVideoPath
    $finalDuration = Assert-TenSecondAvVideo -Probe $finalProbe -Description '最终成片'
    $rawAudioHash = Get-AudioStreamSha256 -FfmpegExecutable $ffmpegCommand.Source -Path $RawVideoPath
    $finalAudioHash = Get-AudioStreamSha256 -FfmpegExecutable $ffmpegCommand.Source -Path $FinalVideoPath
    if ($rawAudioHash -ne $finalAudioHash) { throw '最终成片的原声音频流发生变化。' }
    $Manifest.verification = [ordered]@{
        raw_duration_seconds = $rawDuration
        final_duration_seconds = $finalDuration
        raw_audio_sha256 = $rawAudioHash
        final_audio_sha256 = $finalAudioHash
        audio_stream_preserved = $true
    }
    Write-Manifest -Value $Manifest
    Set-ManifestStatus -Status $verificationStatus
    [Console]::Out.WriteLine((([ordered]@{
        ok = $true
        event = $verificationStatus
        status = $verificationStatus
        task_id = $TaskId
        request_fingerprint = $RequestFingerprint
        manifest = $ManifestPath
        final_video = $FinalVideoPath
    }) | ConvertTo-Json -Compress))
    exit 0
} catch {
    $message = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($env:ARK_API_KEY)) {
        $message = $message.Replace($env:ARK_API_KEY, '<redacted>')
    }
    if ($null -ne $Manifest) {
        try { Set-ManifestStatus -Status 'failed' -Reason $message } catch { }
    }
    [Console]::Error.WriteLine("run-grok-family-video 失败：$message")
    [Console]::Out.WriteLine((([ordered]@{
        ok = $false
        event = 'failed'
        status = 'failed'
        task_id = $TaskId
        request_fingerprint = $RequestFingerprint
        manifest = $ManifestPath
        error = $message
    }) | ConvertTo-Json -Compress))
    exit 1
}

