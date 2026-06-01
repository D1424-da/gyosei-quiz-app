# build_limb_questions.ps1
# Generate per-limb question set from HTML cache.
# choice   -> each limb becomes an OX question
# combo_ox -> each limb already has correct flag; add explanation
# text     -> kept as-is with answer extracted from HTML

param(
    [string]$InputJson  = ".\output\all_questions.json",
    [string]$OutputJson = ".\output\limb_questions.json",
    [string]$CacheDir   = ".\cache\html"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ---- ユーティリティ関数 ----

function Get-CachePath([string]$Url) {
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Url)
    $hash  = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    $sha.Dispose()
    return (Join-Path $CacheDir "$hash.html")
}

function Strip-Html([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
    $t = $Html -replace '(?is)<script[^>]*>.*?</script>', ' '
    $t = $t  -replace '(?is)<style[^>]*>.*?</style>',  ' '
    $t = $t  -replace '(?i)<br\s*/?>', "`n"
    $t = $t  -replace '(?i)</p>',      "`n"
    $t = $t  -replace '(?is)<[^>]+>',  ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t  -replace '[ \t\u3000]+',' '
    $t = $t  -replace "(\r\n|\r|\n){3,}", "`n`n"
    return $t.Trim()
}

# div#kaitou の内容を取得
function Get-KaitouHtml([string]$Html) {
    $m = [regex]::Match($Html, '(?is)<div\s+id="kaitou"[^>]*>(.*?)(?=</article>|</section>\s*</div>|$)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

# 【答え】行を取得
function Get-AnswerText([string]$Html) {
    $m = [regex]::Match($Html, '(?is)[【\[]答え[】\]][：:]\s*([^\n<]{1,300})')
    if ($m.Success) { return (Strip-Html $m.Groups[1].Value).Trim() }
    return ""
}

# kaitouHtml から waku-q / waku-a を位置ベースで抽出
# Returns: PSCustomObject[]  { Type:"q"|"a"; RawHtml; Text }
function Get-WakuItems([string]$KaitouHtml) {
    $items = @()
    $pat   = '(?i)<div\s+class="waku-([qa])">'
    $ms    = [regex]::Matches($KaitouHtml, $pat)

    for ($i = 0; $i -lt $ms.Count; $i++) {
        $m     = $ms[$i]
        $type  = $m.Groups[1].Value
        $start = $m.Index + $m.Length
        $end   = if (($i + 1) -lt $ms.Count) { $ms[$i+1].Index } else { $KaitouHtml.Length }
        $raw   = $KaitouHtml.Substring($start, $end - $start)
        # 末尾の</div>と空白を除去
        $raw   = $raw -replace '(?is)\s*</div>\s*$', ''
        $items += [PSCustomObject]@{
            Type    = $type
            RawHtml = $raw
            Text    = (Strip-Html $raw)
        }
    }
    return $items
}

# waku-a のテキストから肢の正誤判定
# 「ア・・・正しい」「２・・・誤り」などのパターン
function Get-CorrectFromWakuA([string]$Text) {
    $head = $Text.Substring(0, [Math]::Min(200, $Text.Length))

    # 「〇〇・・・正しい / 妥当 / 適切」 → true
    if ($head -match '[・\.。]{2,}\s*(正し|妥当(?![でな])|適切(?![でな])|正確|合致|○)') { return $true }
    # 「〇〇・・・誤り / 不妥当 / 不適切」 → false
    if ($head -match '[・\.。]{2,}\s*(誤り|誤っ|不妥当|妥当でない|不適切|誤りで|×)') { return $false }

    # フォールバック: 先頭行に「正し」「誤り」が含まれているか
    $firstLine = ($head -split "`n")[0]
    if ($firstLine -match '正し') { return $true }
    if ($firstLine -match '誤り|誤っ') { return $false }

    return $null  # 判定不能
}

# 全角数字 → 半角数字
function Normalize-Digit([string]$ch) {
    $cp = [int][char]$ch
    if ($cp -ge 0xFF11 -and $cp -le 0xFF19) { return [string]([char]($cp - 0xFF10 + 0x30)) }
    return $ch
}

# kaitouHtml から「ラベル → {Q, A, Correct}」マップを作成
# choiceラベル: "1"〜"5" (半角)
# combo_oxラベル: "ア"〜"コ"
function Get-WakuAMap([string]$KaitouHtml) {
    $map   = @{}
    $items = Get-WakuItems $KaitouHtml

    $lastQ    = $null
    $lastQRaw = $null
    foreach ($item in $items) {
        if ($item.Type -eq "q") {
            $lastQ    = $item.Text
            $lastQRaw = $item.RawHtml
        } elseif ($item.Type -eq "a" -and $null -ne $lastQ) {
            # 先頭ラベル（数字 or カタカナ）を検出
            $lm = [regex]::Match($lastQ, '^\s*([1-5]|[１-５]|[アイウエオカキクケコ])')
            if ($lm.Success) {
                $label = $lm.Groups[1].Value
                # 全角数字 → 半角
                $cp = [int][char]$label
                if ($cp -ge 0xFF11 -and $cp -le 0xFF19) {
                    $label = [string]([char]($cp - 0xFF10 + 0x30))
                }
                if (-not $map.ContainsKey($label)) {
                    $map[$label] = @{
                        Q       = $lastQ
                        A       = $item.Text
                        Correct = (Get-CorrectFromWakuA $item.Text)
                    }
                }
            }
            $lastQ = $null
        }
    }
    return $map
}

# Extract only the lead sentence (before any kata/numeric limb lines)
function Get-LeadText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    # kata marker pattern: line starting with ア〜コ followed by separator
    $kataMarkerPat = [regex]'(?m)^[ \t\u3000]*[\u30A2\u30A4\u30A6\u30A8\u30AA\u30AB\u30AD\u30AF\u30B1\u30B3][\s\u3000\.\uff0e\.\u3001,::\uff1a\-]'
    # number marker pattern: line starting with 1-5 followed by separator or 1.〜5.
    $numMarkerPat  = [regex]'(?m)^[ \t\u3000]*[1-5\uff11-\uff15][\s\u3000\.\uff0e\.\u3001,::\uff1a]'
    $km = $kataMarkerPat.Match($Text)
    $nm = $numMarkerPat.Match($Text)

    $cutPos = $Text.Length
    if ($km.Success -and $km.Index -lt $cutPos) { $cutPos = $km.Index }
    if ($nm.Success -and $nm.Index -lt $cutPos) { $cutPos = $nm.Index }

    # Also cut at first inline kata marker (e.g. "ア．" not at line start)
    if ($cutPos -eq $Text.Length) {
        $inlineM = [regex]::Match($Text, '[\u30A2\u30A4\u30A6\u30A8\u30AA\u30AB\u30AD\u30AF\u30B1\u30B3][\uff0e\.]')
        if ($inlineM.Success) { $cutPos = $inlineM.Index }
    }

    $lead = $Text.Substring(0, $cutPos).TrimEnd()
    return $lead.TrimEnd()
}

# ---- Main ----
Write-Host "Loading $InputJson ..."
$all = Get-Content $InputJson -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "Loaded $($all.Count) questions."

$result = [System.Collections.ArrayList]::new()
$stats  = @{ choice=0; combo_ox=0; text=0; hit=0; miss=0; limbTotal=0 }

# カタカナ順リスト
$kataList = @(
    [char]0x30A2,[char]0x30A4,[char]0x30A6,[char]0x30A8,[char]0x30AA,
    [char]0x30AB,[char]0x30AD,[char]0x30AF,[char]0x30B1,[char]0x30B3
)

$idx = 0
foreach ($q in $all) {
    $idx++
    if ($idx % 100 -eq 0) { Write-Host "  $idx / $($all.Count) ..." }

    # キャッシュHTMLを読み込む
    $html      = ""
    $kaitou    = ""
    $wakuMap   = @{}
    $answerTxt = ""

    if (-not [string]::IsNullOrWhiteSpace($q.questionUrl)) {
        $cp = Get-CachePath $q.questionUrl
        if (Test-Path $cp) {
            $html      = [System.IO.File]::ReadAllText($cp, [System.Text.Encoding]::UTF8)
            $kaitou    = Get-KaitouHtml $html
            $wakuMap   = Get-WakuAMap   $kaitou
            $answerTxt = Get-AnswerText  $html
            $stats.hit++
        } else {
            $stats.miss++
        }
    }

    # 年度・問題番号を ID から抽出 (例: "R1-3" → year=R1, num=3)
    $idm  = [regex]::Match($q.id, '^([A-Za-z][A-Za-z0-9]*)-(\d+)$')
    $year = if ($idm.Success) { $idm.Groups[1].Value } else { "" }
    $qNum = if ($idm.Success) { [int]$idm.Groups[2].Value } else { 0 }

    switch ($q.answerType) {

        # ----------------------------------------------------------------
        # choice: 5択問題 → 各肢を OX 問題化
        # ----------------------------------------------------------------
        "choice" {
            $stats.choice++
            for ($li = 0; $li -lt @($q.limbs).Count; $li++) {
                $limb  = $q.limbs[$li]
                $label = [string]($li + 1)   # "1"〜"5"

                # 正誤: HTML判定 → correctOption補完
                $correct = $null
                if ($wakuMap.ContainsKey($label)) { $correct = $wakuMap[$label].Correct }
                if ($null -eq $correct) {
                    $correct = ($li -eq ([int]$q.correctOption - 1))
                }

                $expText = if ($wakuMap.ContainsKey($label)) { $wakuMap[$label].A } else { "" }

                $null = $result.Add([PSCustomObject]@{
                    id             = [string]$limb.id
                    parentId       = [string]$q.id
                    year           = $year
                    questionNumber = $qNum
                    subject        = [string]$q.subject
                    category       = [string]$q.category
                    source         = [string]$q.source
                    questionText   = Get-LeadText ([string]$q.questionText)
                    limbText       = [string]$limb.text
                    limbIndex      = $li
                    correct        = [bool]$correct
                    explanation    = $expText
                    answerType     = "choice"
                    questionUrl    = [string]$q.questionUrl
                })
                $stats.limbTotal++
            }
        }

        # ----------------------------------------------------------------
        # combo_ox: 組合せ問題 → 各肢は既に correct 済み
        # ----------------------------------------------------------------
        "combo_ox" {
            $stats.combo_ox++
            for ($li = 0; $li -lt @($q.limbs).Count; $li++) {
                $limb  = $q.limbs[$li]
                $label = if ($li -lt $kataList.Count) { [string]$kataList[$li] } else { [string]($li + 1) }

                $expText = if ($wakuMap.ContainsKey($label)) { $wakuMap[$label].A } else { "" }

                $null = $result.Add([PSCustomObject]@{
                    id             = [string]$limb.id
                    parentId       = [string]$q.id
                    year           = $year
                    questionNumber = $qNum
                    subject        = [string]$q.subject
                    category       = [string]$q.category
                    source         = [string]$q.source
                    questionText   = Get-LeadText ([string]$q.questionText)
                    limbText       = [string]$limb.text
                    limbIndex      = $li
                    correct        = [bool]$limb.correct
                    explanation    = $expText
                    answerType     = "combo_ox"
                    questionUrl    = [string]$q.questionUrl
                })
                $stats.limbTotal++
            }
        }

        # ----------------------------------------------------------------
        # text: 記述式 / 穴埋め → 1問そのまま（解答を付加）
        # ----------------------------------------------------------------
        "text" {
            $stats.text++
            # kaitou全体を解説として使用（解答行より後ろ）
            $expText = if ($kaitou -ne "") { Strip-Html $kaitou } else { "" }

            $null = $result.Add([PSCustomObject]@{
                id             = [string]$q.id
                parentId       = [string]$q.id
                year           = $year
                questionNumber = $qNum
                subject        = [string]$q.subject
                category       = [string]$q.category
                source         = [string]$q.source
                questionText   = [string]$q.questionText
                limbText       = $null
                limbIndex      = $null
                correct        = $null
                answer         = $answerTxt
                explanation    = $expText
                answerType     = "text"
                questionUrl    = [string]$q.questionUrl
            })
            $stats.limbTotal++
        }
    }
}

Write-Host ""
Write-Host "=== Summary ==="
Write-Host "  choice     : $($stats.choice) questions"
Write-Host "  combo_ox   : $($stats.combo_ox) questions"
Write-Host "  text       : $($stats.text) questions"
Write-Host "  cache hits : $($stats.hit)  misses: $($stats.miss)"
Write-Host "  limb items : $($stats.limbTotal)"
Write-Host ""
Write-Host "Writing to $OutputJson ..."
$arr = @($result)
[System.IO.File]::WriteAllText(
    $OutputJson,
    (ConvertTo-Json -Depth 10 -InputObject $arr),
    [System.Text.Encoding]::UTF8
)
Write-Host "Done. $($arr.Count) items written."
