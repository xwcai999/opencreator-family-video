[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptRoot = Join-Path $pluginRoot 'scripts'
$generator = Join-Path $scriptRoot 'generate-family-dialogue.ps1'
$fixture = Join-Path $scriptRoot 'fixtures\family-dialogue-valid.json'
$videoRoot = $pluginRoot
$testRoot = Join-Path $pluginRoot ('.test-dialogue-' + [Guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $validOutput = Join-Path $testRoot 'valid-output.json'
    $text = & pwsh -NoProfile -File $generator -Title 'Breakfast helper' `
        -TeachingGoal 'Ask politely and help with breakfast' -Scene 'A bright family kitchen' `
        -OutputPath $validOutput -VideoRoot $videoRoot -Vocabulary 'help,milk' `
        -Participants 'father,mother,child' -CandidatePath $fixture 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "valid candidate rejected: $text"
    $artifact = Get-Content -Raw $validOutput | ConvertFrom-Json -Depth 30
    Assert-True (@($artifact.dialogue).Count -eq 4) 'dialogue count mismatch'
    Assert-True ([int]$artifact.total_english_words -eq 18) 'word count mismatch'

    $outside = Join-Path ([IO.Path]::GetTempPath()) 'opencreator-family-outside.json'
    [IO.File]::WriteAllText($outside, (Get-Content -Raw $fixture), [Text.UTF8Encoding]::new($false))
    try {
        $outsideText = & pwsh -NoProfile -File $generator -Title x -TeachingGoal x -Scene x `
            -OutputPath (Join-Path $testRoot 'outside-output.json') -VideoRoot $videoRoot `
            -CandidatePath $outside 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -ne 0 -and $outsideText -match 'CandidatePath|视频目录') `
            'outside CandidatePath was not rejected'
    } finally {
        if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Force }
    }
    'PASS valid-contract'
    'PASS candidate-root-guard'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
