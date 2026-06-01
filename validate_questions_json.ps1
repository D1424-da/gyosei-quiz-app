param(
    [string]$Path = ".\\output\\all_questions.json"
)

$ErrorActionPreference = "Stop"

$arr = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
if (-not ($arr -is [System.Array])) { $arr = @($arr) }

$total = $arr.Count
$nullCount = @($arr | Where-Object { $_ -eq $null }).Count
$noId = @($arr | Where-Object { $_ -ne $null -and -not $_.PSObject.Properties['id'] }).Count
$noLimbs = @($arr | Where-Object { $_ -ne $null -and -not $_.PSObject.Properties['limbs'] }).Count
$badLimbs = @($arr | Where-Object { $_ -ne $null -and $_.PSObject.Properties['limbs'] -and -not ($_.limbs -is [System.Array]) }).Count
$emptyLimbs = @($arr | Where-Object { $_ -ne $null -and $_.PSObject.Properties['limbs'] -and (@($_.limbs).Count -eq 0) }).Count

Write-Host "total=$total"
Write-Host "null=$nullCount"
Write-Host "noId=$noId"
Write-Host "noLimbs=$noLimbs"
Write-Host "badLimbs=$badLimbs"
Write-Host "emptyLimbs=$emptyLimbs"

$bad = @($arr | Where-Object {
    $_ -ne $null -and (
        -not $_.PSObject.Properties['id'] -or
        -not $_.PSObject.Properties['limbs'] -or
        -not ($_.limbs -is [System.Array])
    )
} | Select-Object -First 10)

if ($bad.Count -gt 0) {
    Write-Host "sample_bad:";
    $bad | ConvertTo-Json -Depth 4 | Write-Host
}
