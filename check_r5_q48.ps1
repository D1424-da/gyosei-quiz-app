$text = [System.IO.File]::ReadAllText('F:\開発中アプリ\行政書士\output\gyosyo_r5_questions.json', [System.Text.Encoding]::UTF8)
$data = $text | ConvertFrom-Json
$q = $data | Where-Object { $_.questionNumber -eq 48 -or $_.number -eq 48 -or $_.id -like '*48*' }
if (-not $q) {
    Write-Host "questionNumber 48 not found. Checking keys..."
    $first = $data | Select-Object -First 1
    $first | Get-Member -MemberType NoteProperty | Select-Object Name
    Write-Host "First item:"
    $first | ConvertTo-Json -Depth 5
} else {
    $q | ConvertTo-Json -Depth 10
}
