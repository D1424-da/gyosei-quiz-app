param(
    [string]$OutDir = ".\\output"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutDir)) {
    throw "output directory not found: $OutDir"
}

$resolvedOutDir = (Resolve-Path $OutDir).Path
$yearFiles = @(Get-ChildItem -LiteralPath $resolvedOutDir -Filter 'gyosyo_*_questions.json' -File |
    Where-Object { $_.Name -ne 'gyosyo_all_questions.json' } |
    Sort-Object Name)

if ($yearFiles.Count -eq 0) {
    throw "no per-year files found under: $resolvedOutDir"
}

$jsonBodies = @()
foreach ($f in $yearFiles) {
    $raw = [string](Get-Content -Raw -LiteralPath $f.FullName)
    $trimmed = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        throw "invalid JSON array file: $($f.FullName)"
    }

    $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    if (-not [string]::IsNullOrWhiteSpace($inner)) {
        $jsonBodies += $inner
    }
}

if ($jsonBodies.Count -eq 0) {
    throw "no questions found in local per-year files"
}

$json = "[" + [Environment]::NewLine + ($jsonBodies -join ("," + [Environment]::NewLine)) + [Environment]::NewLine + "]"

$mergedFile = Join-Path $resolvedOutDir 'gyosyo_all_questions.json'
$appFile = Join-Path $resolvedOutDir 'all_questions.json'

[System.IO.File]::WriteAllText($mergedFile, $json, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($appFile, $json, [System.Text.Encoding]::UTF8)

Write-Host "offline rebuilt: files=$($yearFiles.Count), non-empty arrays=$($jsonBodies.Count)"
Write-Host "wrote: $mergedFile"
Write-Host "wrote: $appFile"
