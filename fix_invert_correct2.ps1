param()

$invertPattern = 'combo_ox_invert_check'
$outDir = "g:\kaihatsu\gyosyo\output"

# Override with actual path
$outDir = "g:\kai"
$outDir = [System.IO.Path]::GetFullPath("g:\開発中アプリ\行政書士\output")

$pat = [regex]'誤っているもの|妥当でないもの|適切でないもの|誤りであるもの|誤りはどれか'

$yearFiles = Get-ChildItem "$outDir\gyosyo_*.json" | Where-Object { $_.Name -ne 'gyosyo_all_questions.json' }
$totalFixed = 0
$allQuestions = [System.Collections.ArrayList]::new()

foreach ($file in $yearFiles) {
    $data = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $fixedCount = 0
    foreach ($q in $data) {
        if ($q.answerType -eq 'combo_ox' -and $pat.IsMatch($q.questionText)) {
            foreach ($limb in $q.limbs) {
                $limb.correct = -not [bool]$limb.correct
            }
            $fixedCount++
        }
    }
    if ($fixedCount -gt 0) {
        [System.IO.File]::WriteAllText($file.FullName, (ConvertTo-Json -Depth 10 -InputObject @($data)), [System.Text.Encoding]::UTF8)
        Write-Host "Fixed $($file.Name): $fixedCount questions"
        $totalFixed += $fixedCount
    } else {
        Write-Host "No fix needed: $($file.Name)"
    }
    $null = $allQuestions.AddRange($data)
}

Write-Host "Total fixed: $totalFixed"

$allArr = @($allQuestions)
[System.IO.File]::WriteAllText("$outDir\gyosyo_all_questions.json", (ConvertTo-Json -Depth 10 -InputObject $allArr), [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText("$outDir\all_questions.json", (ConvertTo-Json -Depth 10 -InputObject $allArr), [System.Text.Encoding]::UTF8)
Write-Host "Wrote gyosyo_all_questions.json and all_questions.json ($($allArr.Count) questions)"

# Verify H24-52
$h24 = Get-Content "$outDir\gyosyo_h24_questions.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$q52 = $h24 | Where-Object { $_.id -eq 'H24-52' }
Write-Host "H24-52 correctOption=$($q52.correctOption)"
$q52.limbs | ForEach-Object { Write-Host "  $($_.id) correct=$($_.correct)" }
Write-Host "Expected: l0=true l1=true l2=false l3=true l4=false"
