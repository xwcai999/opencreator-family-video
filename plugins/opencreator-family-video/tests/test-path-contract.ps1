[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scripts = Join-Path $pluginRoot 'scripts'
$runner = Join-Path $scripts 'run-grok-family-video.ps1'
$wrapper = Join-Path $scripts 'run-family-english-video.ps1'
$fixture = Join-Path $scripts 'fixtures\family-dialogue-valid.json'
$root = $pluginRoot
$testRoot = Join-Path $root ('.test-path-' + [Guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    $prepare = Join-Path $testRoot 'prepare'
    $output = & pwsh -NoProfile -File $runner -Title 'Offline contract' `
        -Scene 'A family kitchen' -Action 'The family prepares breakfast.' `
        -OutputDirectory $prepare -VideoRoot $root -DialogueMode SingleLine `
        -TargetEnglish 'Please pass the milk.' -ChineseMeaning '请递牛奶。' -PrepareOnly 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "PrepareOnly failed: $output"
    Assert-True (Test-Path -LiteralPath (Join-Path $prepare 'manifest.json')) 'manifest missing'
    Assert-True ((Get-Content -Raw (Join-Path $prepare 'manifest.json')) -match 'planned') 'planned status missing'

    $outside = Join-Path ([IO.Path]::GetTempPath()) 'opencreator-outside-candidate.json'
    [IO.File]::WriteAllText($outside, (Get-Content -Raw $fixture), [Text.UTF8Encoding]::new($false))
    try {
        $blocked = & pwsh -NoProfile -File $wrapper -Title x -TeachingGoal x -Scene x `
            -OutputDirectory (Join-Path $testRoot 'blocked') -VideoRoot $root -CandidatePath $outside `
            -PrepareOnly 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -ne 0 -and $blocked -match 'CandidatePath') 'wrapper allowed outside candidate'
    } finally {
        if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Force }
    }
    'PASS prepare-only-contract'
    'PASS wrapper-candidate-root-guard'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
