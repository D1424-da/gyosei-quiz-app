$path = '.\output\gyosyo_h30_questions.json'
$list = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
if (-not ($list -is [System.Array])) { $list = @($list) }

$idx = -1
for ($i = 0; $i -lt $list.Count; $i++) {
    $item = $list[$i]
    if ($null -eq $item) { continue }
    if (-not ($item.PSObject.Properties.Name -contains 'id')) { continue }
    if ([string]$item.id -eq 'H30-53') { $idx = $i; break }
}
if ($idx -lt 0) { throw 'H30-53 not found' }

$q = $list[$idx]
$explanation = ''
$correctLimb = @($q.limbs | Where-Object { $_.correct -eq $true })[0]
if ($null -ne $correctLimb) { $explanation = [string]$correctLimb.explanation }

$newLimbs = @(
    [PSCustomObject]@{ id = 'H30-53-l0'; text = '近隣の風俗営業に関する情報を提供する、いわゆる風俗案内所'; correct = $true;  explanation = $explanation },
    [PSCustomObject]@{ id = 'H30-53-l1'; text = '店舗を構えて性的好奇心に応えるサービスを提供する、いわゆるファッションヘルス'; correct = $false; explanation = $explanation },
    [PSCustomObject]@{ id = 'H30-53-l2'; text = '射幸心をそそるような遊興用のマシンを備えた、いわゆるゲームセンター'; correct = $false; explanation = $explanation },
    [PSCustomObject]@{ id = 'H30-53-l3'; text = '性的好奇心を煽るような、いわゆるピンクチラシ類を印刷することを業とする事業所'; correct = $true;  explanation = $explanation },
    [PSCustomObject]@{ id = 'H30-53-l4'; text = '店舗を構えずに、異性との性的好奇心を満たすための会話の機会を提供し異性を紹介する営業である、いわゆる無店舗型テレクラ'; correct = $false; explanation = $explanation }
)

$list[$idx] = [PSCustomObject]@{
    id = [string]$q.id
    subject = [string]$q.subject
    category = [string]$q.category
    source = [string]$q.source
    questionText = [string]$q.questionText
    limbs = $newLimbs
    questionUrl = [string]$q.questionUrl
    correctOption = 0
    answerType = 'combo_ox'
}

[System.IO.File]::WriteAllText((Resolve-Path $path), (ConvertTo-Json -Depth 10 -InputObject @($list)), [System.Text.Encoding]::UTF8)
Write-Host 'fixed H30-53 to combo_ox'
