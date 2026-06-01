param(
    [string]$OutDir = ".\\output"
)

$ErrorActionPreference = "Stop"

function Normalize-Digits {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -ge 0xFF10 -and $code -le 0xFF19) {
            [void]$sb.Append([char](0x30 + $code - 0xFF10))
        } else {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function Normalize-KataCombo {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return ([regex]::Replace($Text, '[^アイウエオカキクケコ]', ''))
}

function Parse-KataStatements {
    param([string]$QuestionText)
    $items = @()
    if ([string]::IsNullOrWhiteSpace($QuestionText)) { return $items }
    $lines = @($QuestionText -split "`r?`n")
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $m = [regex]::Match($line, '^\s*([アイウエオカキクケコ])[\s　\.．、,:：-]+(.+)$')
        if (-not $m.Success) { continue }
        $items += [PSCustomObject]@{ Marker = $m.Groups[1].Value; Text = $m.Groups[2].Value.Trim() }
    }
    return $items
}

function Is-InvertedComboQuestion {
    param([string]$QuestionText)
    if ([string]::IsNullOrWhiteSpace($QuestionText)) { return $false }
    return $QuestionText -match '誤っているもの|妥当でないもの|適切でないもの|誤りであるもの|誤りはどれか'
}

if (-not (Test-Path $OutDir)) {
    throw "output directory not found: $OutDir"
}

$resolvedOutDir = (Resolve-Path $OutDir).Path
$yearFiles = @(Get-ChildItem -LiteralPath $resolvedOutDir -Filter 'gyosyo_*_questions.json' -File |
    Where-Object { $_.Name -ne 'gyosyo_all_questions.json' } |
    Sort-Object Name)

$convertedTotal = 0

foreach ($f in $yearFiles) {
    $changed = $false
    $parsedRoot = Get-Content -Raw -Encoding UTF8 -LiteralPath $f.FullName | ConvertFrom-Json
    $list = @($parsedRoot)

    for ($i = 0; $i -lt $list.Count; $i++) {
        $q = $list[$i]
        if ([string]$q.answerType -ne 'choice') { continue }
        $limbs = @($q.limbs)
        if ($limbs.Count -lt 2) { continue }

        $statements = @(Parse-KataStatements -QuestionText ([string]$q.questionText))
        if ($statements.Count -lt 3) { continue }

        $correctLimb = $null
        foreach ($lb in $limbs) {
            if ($lb.correct -eq $true) { $correctLimb = $lb; break }
        }
        if ($null -eq $correctLimb) { continue }

        $combo = Normalize-KataCombo ([string]$correctLimb.text)
        if ([string]::IsNullOrWhiteSpace($combo)) { continue }

        $isInverted = Is-InvertedComboQuestion -QuestionText ([string]$q.questionText)
        $explanation = [string]$correctLimb.explanation
        $qid = [string]$q.id

        $newLimbs = @()
        for ($j = 0; $j -lt $statements.Count; $j++) {
            $st = $statements[$j]
            $contains = $combo.Contains([string]$st.Marker)
            $isCorrect = if ($isInverted) { -not $contains } else { $contains }
            $newLimbs += [PSCustomObject]@{
                id = "${qid}-l$j"
                text = [string]$st.Text
                correct = [bool]$isCorrect
                explanation = $explanation
            }
        }

        $q.limbs = @($newLimbs)
        $q.answerType = 'combo_ox'
        $q.correctOption = 0
        $list[$i] = $q
        $changed = $true
        $convertedTotal++
    }

    if ($changed) {
        [System.IO.File]::WriteAllText($f.FullName, (ConvertTo-Json -Depth 10 -InputObject @($list)), [System.Text.Encoding]::UTF8)
    }
}

Write-Host "converted questions: $convertedTotal"
