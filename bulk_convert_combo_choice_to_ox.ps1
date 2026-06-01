param(
    [string]$OutDir = ".\\output"
)

$ErrorActionPreference = "Stop"

function Normalize-KataCombo {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return ([regex]::Replace($Text, '[^アイウエオカキクケコ]', ''))
}

function Is-InvertedComboQuestion {
    param([string]$QuestionText)
    if ([string]::IsNullOrWhiteSpace($QuestionText)) { return $false }
    return $QuestionText -match '誤っているもの|妥当でないもの|適切でないもの|誤りであるもの|誤りはどれか'
}

function Parse-StatementLines {
    param([string]$QuestionText)

    $items = @()
    if ([string]::IsNullOrWhiteSpace($QuestionText)) { return $items }

    $normalized = [string]$QuestionText -replace "`r", ""
    $lines = @($normalized -split "`n")
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $m = [regex]::Match([string]$line, '^\s*([アイウエオカキクケコ])[．\.、,:：\s　-]+(.+)$')
        if (-not $m.Success) { continue }
        $items += [PSCustomObject]@{
            Marker = [string]$m.Groups[1].Value
            Text = [string]$m.Groups[2].Value.Trim()
        }
    }

    return $items
}

function Is-ComboOptionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $t = [string]$Text
    return [regex]::IsMatch($t, '^\s*[（\(]?\s*[アイウエオカキクケコ](?:\s*[・、,\s　]\s*[アイウエオカキクケコ])+\s*[）\)]?\s*$')
}

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

$converted = 0
$convertedIds = @()

foreach ($f in $yearFiles) {
    $changed = $false
    $arr = @(Get-Content -Raw -Encoding UTF8 -LiteralPath $f.FullName | ConvertFrom-Json)

    for ($i = 0; $i -lt $arr.Count; $i++) {
        $q = $arr[$i]
        if ($null -eq $q) { continue }

        $answerType = [string]$q.answerType
        if ($answerType -ne 'choice') { continue }

        $limbs = @($q.limbs)
        if ($limbs.Count -lt 2) { continue }

        $optionLikeCount = 0
        foreach ($lb in $limbs) {
            if (Is-ComboOptionText ([string]$lb.text)) { $optionLikeCount++ }
        }
        if ($optionLikeCount -lt 2) { continue }

        $statements = @(Parse-StatementLines -QuestionText ([string]$q.questionText))
        if ($statements.Count -lt 3) { continue }

        $correctLimb = @($limbs | Where-Object { $_.correct -eq $true })[0]
        if ($null -eq $correctLimb) { continue }

        $combo = Normalize-KataCombo ([string]$correctLimb.text)
        if ([string]::IsNullOrWhiteSpace($combo)) { continue }

        $isInverted = Is-InvertedComboQuestion -QuestionText ([string]$q.questionText)
        $newLimbs = @()
        for ($j = 0; $j -lt $statements.Count; $j++) {
            $st = $statements[$j]
            $contains = $combo.Contains([string]$st.Marker)
            $isCorrect = if ($isInverted) { -not $contains } else { $contains }
            $newLimbs += [PSCustomObject]@{
                id = "${($q.id)}-l$j"
                text = [string]$st.Text
                correct = [bool]$isCorrect
                explanation = [string]$correctLimb.explanation
            }
        }

        $q.limbs = @($newLimbs)
        $q.answerType = 'combo_ox'
        $q.correctOption = 0

        $arr[$i] = $q
        $changed = $true
        $converted++
        $convertedIds += [string]$q.id
    }

    if ($changed) {
        [System.IO.File]::WriteAllText($f.FullName, (ConvertTo-Json -Depth 10 -InputObject @($arr)), [System.Text.Encoding]::UTF8)
    }
}

Write-Host "converted questions: $converted"
if ($convertedIds.Count -gt 0) {
    Write-Host ("converted ids: " + ($convertedIds -join ', '))
}
