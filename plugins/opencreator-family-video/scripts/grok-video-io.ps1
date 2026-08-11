[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('List', 'EnsureDirectory', 'Copy', 'Download', 'Hash', 'Probe')]
    [string]$Operation,

    [string]$Path,
    [string]$Source,
    [string]$Destination,
    [string]$SessionId,
    [string]$SessionCwd,
    [uri]$Uri,
    [string]$VideoRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VideoRoot)) { $VideoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\video-output')) }
$allowedRoot = [IO.Path]::GetFullPath($VideoRoot).TrimEnd('\')
$sessionMediaRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.grok\sessions')).TrimEnd('\') + '\'

function Resolve-VideoPath {
    param([string]$Value, [switch]$MustExist)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw '路径为空。'
    }
    if ($Value -match '^[~]' -or $Value -match '\$\{|\$env:|%[A-Za-z_][A-Za-z0-9_]*%' -or
        $Value -match '^(\\\\|\\\\[?.]\\)') {
        throw '路径包含变量或 UNC/设备语法。'
    }
    foreach ($segment in ($Value -split '[\\/]')) {
        if ($segment -notin @('', '.', '..') -and $segment -match '[ .]$') {
            throw '路径段不能以点或空格结尾。'
        }
    }
    $full = if ([IO.Path]::IsPathRooted($Value)) {
        [IO.Path]::GetFullPath($Value)
    } else {
        [IO.Path]::GetFullPath((Join-Path $allowedRoot $Value))
    }
    $prefix = $allowedRoot + '\'
    if (-not $full.Equals($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "仅允许访问 $allowedRoot。"
    }
    if ($full.StartsWith((Join-Path $allowedRoot '.grok'), [StringComparison]::OrdinalIgnoreCase)) {
        throw '禁止访问守卫配置目录。'
    }
    $relative = [IO.Path]::GetRelativePath($allowedRoot, $full)
    $cursor = $allowedRoot
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { break }
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "禁止通过链接或联接点访问：$cursor"
        }
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) {
        throw "文件不存在：$full"
    }
    return $full
}

function Resolve-CopySource {
    param([string]$Value, [string]$ExpectedSessionId, [string]$ExpectedSessionCwd)
    try {
        return Resolve-VideoPath -Value $Value -MustExist
    } catch {
        if (-not [IO.Path]::IsPathRooted($Value)) { throw }
        $full = [IO.Path]::GetFullPath($Value)
        if ([string]::IsNullOrWhiteSpace($ExpectedSessionId) -or [string]::IsNullOrWhiteSpace($ExpectedSessionCwd)) {
            throw '复制会话媒体时必须提供 SessionId 和 SessionCwd。'
        }
        $encodedCwd = [uri]::EscapeDataString([IO.Path]::GetFullPath($ExpectedSessionCwd).TrimEnd('\', '/'))
        $expectedRoot = [IO.Path]::GetFullPath((Join-Path $sessionMediaRoot "$encodedCwd\$ExpectedSessionId")).TrimEnd('\') + '\'
        if (-not $full.StartsWith($sessionMediaRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not $full.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $full -notmatch '(?i)\\(images|videos)\\[^\\]+\.(jpg|jpeg|png|webp|gif|mp4|mov|webm)$' -or
            -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw '复制源只能位于视频目录或 Grok 会话的媒体缓存。'
        }
        return $full
    }
}

switch ($Operation) {
    'List' {
        $target = Resolve-VideoPath -Value $(if ($Path) { $Path } else { $allowedRoot }) -MustExist
        Get-ChildItem -LiteralPath $target -Force | Select-Object Name, Length, LastWriteTime, Attributes
    }
    'EnsureDirectory' {
        $target = Resolve-VideoPath -Value $Path
        New-Item -ItemType Directory -Path $target -Force | Select-Object FullName
    }
    'Copy' {
        $from = Resolve-CopySource -Value $Source -ExpectedSessionId $SessionId -ExpectedSessionCwd $SessionCwd
        $to = Resolve-VideoPath -Value $Destination
        Copy-Item -LiteralPath $from -Destination $to -Force
        Get-Item -LiteralPath $to | Select-Object FullName, Length, LastWriteTime
    }
    'Download' {
        if ($null -eq $Uri -or $Uri.Scheme -ne 'https') {
            throw '只允许从 HTTPS 地址下载。'
        }
        $to = Resolve-VideoPath -Value $Destination
        Invoke-WebRequest -Uri $Uri -OutFile $to -UseBasicParsing
        Get-Item -LiteralPath $to | Select-Object FullName, Length, LastWriteTime
    }
    'Hash' {
        $target = Resolve-VideoPath -Value $Path -MustExist
        Get-FileHash -LiteralPath $target -Algorithm SHA256
    }
    'Probe' {
        $target = Resolve-VideoPath -Value $Path -MustExist
        $ffprobe = Get-Command ffprobe -ErrorAction Stop
        & $ffprobe.Source -v error -show_entries format=duration,size,format_name -of json -- $target
        if ($LASTEXITCODE -ne 0) { throw "ffprobe 检查失败：$target" }
    }
}

