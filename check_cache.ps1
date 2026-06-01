param([string]$Url = "", [string]$AnswerType = "text")

# all_questions.jsonからURLを取得してキャッシュを確認
$all = Get-Content ".\output\all_questions.json" -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Url -eq "") {
    $Url = ($all | Where-Object { $_.answerType -eq $AnswerType } | Select-Object -First 1).questionUrl
}

Write-Host "URL: $Url"

$sha = [System.Security.Cryptography.SHA256]::Create()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($Url)
$hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
$sha.Dispose()

Write-Host "Hash: $hash"

$cachePath = ".\cache\html\$hash.html"
Write-Host "Cache exists: $(Test-Path $cachePath)"

if (Test-Path $cachePath) {
    $html = [System.IO.File]::ReadAllText($cachePath, [System.Text.Encoding]::UTF8)
    Write-Host "HTML length: $($html.Length)"

    # article要素の内容を抽出
    $article = [regex]::Match($html, '(?is)<article[^>]*>(.*?)</article>')
    if ($article.Success) {
        Write-Host "=== article content (first 2000 chars) ==="
        Write-Host $article.Groups[1].Value.Substring(0, [Math]::Min(2000, $article.Groups[1].Value.Length))
    } else {
        # メインコンテンツ
        $main = [regex]::Match($html, '(?is)<div[^>]*class="[^"]*entry-content[^"]*"[^>]*>(.*?)</div>')
        if ($main.Success) {
            Write-Host "=== entry-content (first 2000) ==="
            Write-Host $main.Groups[1].Value.Substring(0, [Math]::Min(2000, $main.Groups[1].Value.Length))
        } else {
            # body全体
            Write-Host "=== body (first 3000) ==="
            $body = [regex]::Match($html, '(?is)<body[^>]*>(.*?)</body>')
            if ($body.Success) {
                Write-Host $body.Groups[1].Value.Substring(0, [Math]::Min(3000, $body.Groups[1].Value.Length))
            }
        }
    }

    # クラス名リスト
    Write-Host "=== classes ==="
    $classes = [regex]::Matches($html, 'class="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $classes | Select-Object -First 40
}
