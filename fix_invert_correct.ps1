# fix_invert_correct.ps1
# combo_ox「妥当でない系」問題の limbs[].correct を正しく反転するスクリプト

$invertPattern = '誤っているもの|妥当でないもの|適切でないもの|誤りであるもの|誤りはどれか'
$outDir = "g:\開発中アプリ\行政書士\output"

# 年度別JSONファイルを修正
$yearFiles = Get-ChildItem "$outDir\gyosyo_*.json" | Where-Object { $_.Name -ne 'gyosyo_all_questions.json' }
$totalFixed = 0
$allQuestions = @()

foreach ($file in $yearFiles) {
    $data = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $fixedCount = 0
    foreach ($q in $data) {
        if ($q.answerType -eq 'combo_ox' -and $q.questionText -match $invertPattern) {
            foreach ($limb in $q.limbs) {
                $limb.correct = -not [bool]$limb.correct
            }
            $fixedCount++
        }
    }
    if ($fixedCount -gt 0) {
        [System.IO.File]::WriteAllText($file.FullName, (ConvertTo-Json -Depth 10 -InputObject @($data)), [System.Text.Encoding]::UTF8)
        Write-Host "$($file.Name): $fixedCount 件修正"
        $totalFixed += $fixedCount
    } else {
        Write-Host "$($file.Name): 修正なし"
    }
    $allQuestions += $data
}

Write-Host ""
Write-Host "=== 合計 $totalFixed 件修正完了 ==="
Write-Host ""

# gyosyo_all_questions.json を再生成
$allOutFile = "$outDir\gyosyo_all_questions.json"
[System.IO.File]::WriteAllText($allOutFile, (ConvertTo-Json -Depth 10 -InputObject @($allQuestions)), [System.Text.Encoding]::UTF8)
Write-Host "gyosyo_all_questions.json を更新しました ($($allQuestions.Count) 問)"

# all_questions.json を gyosyo_all_questions.json と同期
$allFile = "$outDir\all_questions.json"
[System.IO.File]::WriteAllText($allFile, (ConvertTo-Json -Depth 10 -InputObject @($allQuestions)), [System.Text.Encoding]::UTF8)
Write-Host "all_questions.json を更新しました ($($allQuestions.Count) 問)"

# H24-52 の検証
Write-Host ""
Write-Host "=== H24-52 検証 ==="
$h24 = Get-Content "$outDir\gyosyo_h24_questions.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$q52 = $h24 | Where-Object { $_.id -eq 'H24-52' }
Write-Host "correctOption: $($q52.correctOption)"
$q52.limbs | ForEach-Object { Write-Host "  $($_.id) correct=$($_.correct)" }
Write-Host ""
Write-Host "期待値: l0=true, l1=true, l2=false, l3=true, l4=false"
