$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$VideoIoScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'grok-video-io.ps1'))

function Write-Decision {
    param(
        [ValidateSet('allow', 'deny')]
        [string]$Decision,
        [string]$Reason = ''
    )

    $result = [ordered]@{ decision = $Decision }
    if ($Reason) {
        $result.reason = $Reason
    }
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress))
}

function Get-FullCandidatePath {
    param([string]$Value, [string]$BaseDirectory)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw '路径为空。'
    }
    if ($Value -match '[\x00]') {
        throw '路径包含不允许的空字符。'
    }
    if ($Value -match '^[~]' -or $Value -match '\$\{|\$env:|%[^%]+%') {
        throw '路径不能使用变量或用户目录缩写。'
    }
    if ($Value -match '^(\\\\|\\\\[?.]\\)') {
        throw '不允许 UNC 或设备路径。'
    }
    foreach ($segment in ($Value -split '[\\/]')) {
        if ($segment -notin @('', '.', '..') -and $segment -match '[ .]$') {
            throw '不允许带尾随点或空格的路径段。'
        }
    }

    $wildcardIndex = $Value.IndexOfAny([char[]]'*?[')
    $pathPart = if ($wildcardIndex -ge 0) { $Value.Substring(0, $wildcardIndex) } else { $Value }
    if ([string]::IsNullOrWhiteSpace($pathPart)) {
        $pathPart = '.'
    }
    if (-not [IO.Path]::IsPathRooted($pathPart)) {
        $pathPart = Join-Path -Path $BaseDirectory -ChildPath $pathPart
    }
    return [IO.Path]::GetFullPath($pathPart).TrimEnd('\', '/')
}

function Test-NoReparseTraversal {
    param([string]$FullPath, [string]$AllowedRoot)

    $relative = [IO.Path]::GetRelativePath($AllowedRoot, $FullPath)
    if ($relative -eq '.') { return $true }
    $cursor = $AllowedRoot
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
        $cursor = Join-Path -Path $cursor -ChildPath $segment
        if (-not (Test-Path -LiteralPath $cursor)) { break }
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
    }
    return $true
}

function Test-InAllowedRoot {
    param([string]$Value, [string]$BaseDirectory, [string]$AllowedRoot)

    if (-not [IO.Path]::IsPathRooted($Value)) {
        if ([string]::IsNullOrWhiteSpace($BaseDirectory)) {
            return $false
        }
        $baseFull = [IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\', '/')
        $basePrefix = $AllowedRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $baseFull.Equals($AllowedRoot, [StringComparison]::OrdinalIgnoreCase) -and
            -not $baseFull.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    try {
        $full = Get-FullCandidatePath -Value $Value -BaseDirectory $BaseDirectory
    } catch {
        return $false
    }
    $rootWithSeparator = $AllowedRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $inside = $full.Equals($AllowedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { return $false }

    $protected = Join-Path -Path $AllowedRoot -ChildPath '.grok'
    $protectedWithSeparator = $protected.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.Equals($protected, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($protectedWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return Test-NoReparseTraversal -FullPath $full -AllowedRoot $AllowedRoot
}

function Test-SessionMediaPath {
    param([string]$Value, [string]$SessionId, [string]$Cwd)

    if ([string]::IsNullOrWhiteSpace($Value) -or [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($Cwd) -or
        -not [IO.Path]::IsPathRooted($Value)) {
        return $false
    }
    $full = [IO.Path]::GetFullPath($Value)
    $encodedCwd = [uri]::EscapeDataString([IO.Path]::GetFullPath($Cwd).TrimEnd('\', '/'))
    $expectedRoot = Join-Path $env:USERPROFILE ".grok\sessions\$encodedCwd\$SessionId\images"
    $expectedPrefix = [IO.Path]::GetFullPath($expectedRoot).TrimEnd('\') + '\'
    if (-not $full.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $full -notmatch '(?i)\.(jpg|jpeg|png|webp|gif|mp4|mov|webm)$') {
        return $false
    }
    return $true
}

function Test-InRuntimeReadRoot {
    param([string]$Value, [string]$BaseDirectory)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try {
        $full = Get-FullCandidatePath -Value $Value -BaseDirectory $BaseDirectory
    } catch {
        return $false
    }
    $roots = @(
        (Join-Path $env:USERPROFILE '.grok\bundled'),
        (Join-Path $env:USERPROFILE '.grok\docs\user-guide')
    )
    foreach ($root in $roots) {
        $normalizedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $prefix = $normalizedRoot + '\'
        if ($full.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-InputValues {
    param([object]$InputObject, [string[]]$Names)

    $values = [Collections.Generic.List[string]]::new()
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        if ($property.Value -is [string]) {
            $values.Add([string]$property.Value)
        } elseif ($property.Value -is [Collections.IEnumerable]) {
            foreach ($entry in $property.Value) {
                if ($entry -is [string]) { $values.Add([string]$entry) }
            }
        }
    }
    return $values
}

function Get-PathLikeValues {
    param([object]$Value, [string]$PropertyName = '')

    $values = [Collections.Generic.List[string]]::new()
    if ($null -eq $Value) { return $values }
    if ($Value -is [string]) {
        if ($PropertyName -match '(?i)^(path|paths|file|files|file_path|filePath|target_file|directory|target_directory|root|cwd|source|destination|output|input_image|input_images|referenced_image_paths)$') {
            $values.Add([string]$Value)
        }
        return $values
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            foreach ($text in (Get-PathLikeValues -Value $entry.Value -PropertyName ([string]$entry.Key))) { $values.Add($text) }
        }
        return $values
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($entry in $Value) {
            foreach ($text in (Get-PathLikeValues -Value $entry -PropertyName $PropertyName)) { $values.Add($text) }
        }
        return $values
    }
    foreach ($property in $Value.PSObject.Properties) {
        foreach ($text in (Get-PathLikeValues -Value $property.Value -PropertyName $property.Name)) { $values.Add($text) }
    }
    return $values
}

function Use-StrictMediaBudget {
    param(
        [string]$ToolName,
        [string]$SessionId,
        [string]$AllowedRoot
    )

    if ($env:GROK_VIDEO_MEDIA_BUDGET -ne 'strict-v1') { return }
    if ($ToolName -in @('image_gen', 'reference_to_video')) {
        throw "严格媒体额度禁止调用 $ToolName；只允许一次 image_edit 和一次 image_to_video。"
    }
    if ($ToolName -notin @('image_edit', 'image_to_video')) { return }
    if ($SessionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw '严格媒体额度要求有效的 Grok 会话 ID。'
    }

    $stateRootValue = $env:GROK_VIDEO_MEDIA_STATE_ROOT
    $taskOutputValue = $env:GROK_VIDEO_TASK_OUTPUT
    if ([string]::IsNullOrWhiteSpace($stateRootValue) -or [string]::IsNullOrWhiteSpace($taskOutputValue)) {
        throw '严格媒体额度缺少状态目录或任务输出目录。'
    }
    if (-not [IO.Path]::IsPathRooted($stateRootValue) -or -not [IO.Path]::IsPathRooted($taskOutputValue)) {
        throw '严格媒体额度目录必须使用绝对路径。'
    }
    $stateRoot = Get-FullCandidatePath -Value $stateRootValue -BaseDirectory $AllowedRoot
    $taskOutput = Get-FullCandidatePath -Value $taskOutputValue -BaseDirectory $AllowedRoot
    if ($stateRoot.Equals($AllowedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-InAllowedRoot -Value $stateRoot -BaseDirectory $AllowedRoot -AllowedRoot $AllowedRoot) -or
        -not (Test-InAllowedRoot -Value $taskOutput -BaseDirectory $AllowedRoot -AllowedRoot $AllowedRoot)) {
        throw '严格媒体额度状态目录和任务输出目录必须位于视频目录内。'
    }

    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    if (-not (Test-NoReparseTraversal -FullPath $stateRoot -AllowedRoot $AllowedRoot)) {
        throw '严格媒体额度状态目录不能经过链接或重解析点。'
    }
    $statePath = Join-Path $stateRoot "$SessionId.json"
    $lockPath = Join-Path $stateRoot "$SessionId.lock"
    $lock = $null
    foreach ($attempt in 1..20) {
        try {
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            break
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 25
        }
    }
    if ($null -eq $lock) { throw '严格媒体额度状态正被占用，已安全拒绝本次调用。' }

    try {
        $state = if (Test-Path -LiteralPath $statePath) {
            Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        } else {
            [pscustomobject]@{
                schema_version = 1
                session_id = $SessionId
                task_output = $taskOutput
                image_edit_count = 0
                image_to_video_count = 0
                created_at = [DateTimeOffset]::UtcNow.ToString('o')
                updated_at = [DateTimeOffset]::UtcNow.ToString('o')
            }
        }
        if ([string]$state.session_id -ne $SessionId -or
            -not ([string]$state.task_output).Equals($taskOutput, [StringComparison]::OrdinalIgnoreCase)) {
            throw '严格媒体额度状态与当前会话或任务不匹配。'
        }
        $editCount = [int]$state.image_edit_count
        $videoCount = [int]$state.image_to_video_count
        if ($editCount -lt 0 -or $videoCount -lt 0) { throw '严格媒体额度状态损坏。' }

        if ($ToolName -eq 'image_edit') {
            if ($editCount -ge 1 -or $videoCount -ge 1) {
                throw '本会话的一次 image_edit 额度已经使用，禁止重试或追加生成。'
            }
            $state.image_edit_count = 1
        } else {
            if ($editCount -ne 1) {
                throw 'image_to_video 只能在唯一一次 image_edit 之后调用。'
            }
            if ($videoCount -ge 1) {
                throw '本会话的一次 image_to_video 额度已经使用，禁止重试或追加生成。'
            }
            $state.image_to_video_count = 1
        }
        $state.updated_at = [DateTimeOffset]::UtcNow.ToString('o')
        $tempPath = Join-Path $stateRoot "$SessionId.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
            [IO.File]::Move($tempPath, $statePath, $true)
        } finally {
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
        }
    } finally {
        $lock.Dispose()
    }
}

try {
    $raw = [Console]::In.ReadToEnd()
    $allowedRootValue = $env:GROK_VIDEO_ONLY_ROOT
    if ([string]::IsNullOrWhiteSpace($allowedRootValue)) {
        Write-Decision -Decision allow
        exit 0
    }

    $event = $raw | ConvertFrom-Json
    if ($event.hookEventName -ne 'pre_tool_use') {
        Write-Decision -Decision allow
        exit 0
    }
    if ($event.toolInputTruncated -eq $true) {
        Write-Decision -Decision deny -Reason '视频目录守卫无法检查被截断的工具参数。'
        exit 2
    }

    $allowedRoot = [IO.Path]::GetFullPath($allowedRootValue).TrimEnd('\', '/')
    $baseDirectory = if ($event.cwd) { [string]$event.cwd } else { '' }
    $toolName = ([string]$event.toolName).ToLowerInvariant()
    $toolName = switch ($toolName) {
        'read' { 'read_file' }
        'edit' { 'search_replace' }
        'write' { 'search_replace' }
        'multiedit' { 'search_replace' }
        'glob' { 'list_dir' }
        'listdir' { 'list_dir' }
        'bash' { 'run_terminal_command' }
        default { $toolName }
    }
    $toolInput = $event.toolInput

    if ($toolName -in @('read_file', 'search_replace', 'list_dir', 'grep', 'view_image', 'read_image')) {
        $paths = Get-InputValues -InputObject $toolInput -Names @(
            'path', 'filePath', 'file_path', 'target_file', 'directory', 'target_directory',
            'root', 'cwd', 'paths', 'files',
            'includePath', 'include_path', 'searchPath', 'search_path'
        )
        if ($paths.Count -eq 0) {
            Write-Decision -Decision deny -Reason "视频目录守卫未识别到 $toolName 的路径参数。"
            exit 2
        }
        foreach ($path in $paths) {
            $runtimeReadAllowed = $toolName -in @('read_file', 'list_dir', 'grep') -and
                (Test-InRuntimeReadRoot -Value $path -BaseDirectory $baseDirectory)
            if (-not $runtimeReadAllowed -and
                -not (Test-InAllowedRoot -Value $path -BaseDirectory $baseDirectory -AllowedRoot $allowedRoot)) {
                Write-Decision -Decision deny -Reason "仅允许访问 $allowedRoot；已阻止：$path"
                exit 2
            }
        }
        Write-Decision -Decision allow
        exit 0
    }

    if ($toolName -eq 'run_terminal_command') {
        $command = [string]$toolInput.command
        $helper = $VideoIoScript
        $escapedHelper = [Regex]::Escape($helper)
        $trimmed = $command.Trim()
        $helperPattern = "^&\s*'$escapedHelper'\s+"
        $tail = if ($trimmed.Length -gt 1) { $trimmed.Substring(1) } else { '' }
        if ($trimmed -notmatch $helperPattern -or
            $tail -match '[;&|<>`\r\n]' -or
            $trimmed -match '\$\(|\$env:') {
            Write-Decision -Decision deny -Reason "视频模式禁止任意终端命令；只能调用受限助手 $helper。"
            exit 2
        }
        if ($trimmed -match '(?i)\\\.grok\\sessions\\') {
            $encodedCwd = [uri]::EscapeDataString([IO.Path]::GetFullPath($baseDirectory).TrimEnd('\', '/'))
            $expectedSessionPart = '\sessions\' + $encodedCwd + '\' + [string]$event.sessionId + '\'
            if ([string]::IsNullOrWhiteSpace([string]$event.sessionId) -or
                $trimmed -notmatch [Regex]::Escape($expectedSessionPart) -or
                $trimmed -notmatch '(?i)\\(images|videos)\\[^''"]+\.(jpg|jpeg|png|webp|gif|mp4|mov|webm)') {
                Write-Decision -Decision deny -Reason '会话媒体复制只能引用当前工作区、当前会话的 images/videos 文件。'
                exit 2
            }
        }
        Write-Decision -Decision allow
        exit 0
    }

    if ($toolName -match '(?i)(image|video)') {
        $mediaPaths = Get-InputValues -InputObject $toolInput -Names @(
            'image', 'images', 'path', 'filePath', 'file_path', 'referenced_image_paths',
            'input_image', 'input_images', 'video', 'videos'
        )
        foreach ($path in $mediaPaths) {
            if (-not (Test-InAllowedRoot -Value $path -BaseDirectory $baseDirectory -AllowedRoot $allowedRoot) -and
                -not (Test-SessionMediaPath -Value $path -SessionId ([string]$event.sessionId) -Cwd $baseDirectory)) {
                Write-Decision -Decision deny -Reason "视频工具只能引用视频目录或本次 Grok 会话的媒体缓存；已阻止：$path"
                exit 2
            }
        }
        Use-StrictMediaBudget -ToolName $toolName -SessionId ([string]$event.sessionId) -AllowedRoot $allowedRoot
        Write-Decision -Decision allow
        exit 0
    }

    # 未知工具若显式携带绝对本地路径，仍执行目录边界检查；无本地路径的网络/模型工具保持原行为。
    foreach ($candidate in (Get-PathLikeValues -Value $toolInput)) {
        if ($candidate -notmatch '^(?i)([a-z]:[\\/]|\\\\)') { continue }
        if (-not (Test-InAllowedRoot -Value $candidate -BaseDirectory $baseDirectory -AllowedRoot $allowedRoot) -and
            -not (Test-SessionMediaPath -Value $candidate -SessionId ([string]$event.sessionId) -Cwd $baseDirectory)) {
            Write-Decision -Decision deny -Reason "未知工具携带视频目录外的本地路径；已阻止：$candidate"
            exit 2
        }
    }

    Write-Decision -Decision allow
    exit 0
} catch {
    Write-Decision -Decision deny -Reason "视频目录守卫检查失败，已按安全策略拒绝：$($_.Exception.Message)"
    exit 2
}

