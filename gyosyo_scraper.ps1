param(
    [string]$IndexUrl = "https://gyosyo.info/%E8%A1%8C%E6%94%BF%E6%9B%B8%E5%A3%AB%E3%81%AE%E9%81%8E%E5%8E%BB%E5%95%8F%E9%9B%86%EF%BC%88%E5%95%8F%E9%A1%8C%E3%81%A8%E8%A7%A3%E8%AA%AC%EF%BC%89/",
    [string]$OutDir = ".\\output",
    [string]$CacheDir = ".\cache\html",
    [string]$Year = "",
    [int]$StartQuestion = 1,
    [int]$EndQuestion = 60,
    [switch]$All,
    [switch]$Offline,
    [switch]$AllowNetwork
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36"
}

# Detects "wrong/not-appropriate" question types using UTF-8 byte arrays to avoid
# encoding issues with Japanese string literals in the script file.
function Test-IsInvertedQuestion {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    $utf8 = [System.Text.Encoding]::UTF8
    $kw1 = $utf8.GetString([byte[]]@(0xE8,0xAA,0xA4,0xE3,0x81,0xA3,0xE3,0x81,0xA6,0xE3,0x81,0x84,0xE3,0x82,0x8B,0xE3,0x82,0x82,0xE3,0x81,0xAE)) # 誤っているもの
    $kw2 = $utf8.GetString([byte[]]@(0xE5,0xA6,0xA5,0xE5,0xBD,0x93,0xE3,0x81,0xA7,0xE3,0x81,0xAA,0xE3,0x81,0x84,0xE3,0x82,0x82,0xE3,0x81,0xAE)) # 妥当でないもの
    $kw3 = $utf8.GetString([byte[]]@(0xE9,0x81,0xA9,0xE5,0x88,0x87,0xE3,0x81,0xA7,0xE3,0x81,0xAA,0xE3,0x81,0x84,0xE3,0x82,0x82,0xE3,0x81,0xAE)) # 適切でないもの
    $kw4 = $utf8.GetString([byte[]]@(0xE8,0xAA,0xA4,0xE3,0x82,0x8A,0xE3,0x81,0xA7,0xE3,0x81,0x82,0xE3,0x82,0x8B,0xE3,0x82,0x82,0xE3,0x81,0xAE)) # 誤りであるもの
    $kw5 = $utf8.GetString([byte[]]@(0xE8,0xAA,0xA4,0xE3,0x82,0x8A,0xE3,0x81,0xAF,0xE3,0x81,0xA9,0xE3,0x82,0x8C,0xE3,0x81,0x8B))              # 誤りはどれか
    return $Text.Contains($kw1) -or $Text.Contains($kw2) -or $Text.Contains($kw3) -or $Text.Contains($kw4) -or $Text.Contains($kw5)
}

function Get-Html {
    param([string]$Url)
    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Url)
        $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }

    $cachePath = Join-Path $CacheDir ($hash + '.html')
    if (Test-Path $cachePath) {
        return [System.IO.File]::ReadAllText($cachePath, [System.Text.Encoding]::UTF8)
    }

    if ($Offline -or -not $AllowNetwork) {
        throw "cache miss without network access: $Url"
    }

    $resp = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 40
    $html = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    [System.IO.File]::WriteAllText($cachePath, $html, [System.Text.Encoding]::UTF8)
    return $html
}

function Strip-Html {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }

    $t = $Html -replace '(?is)<script[^>]*>.*?</script>', ' '
    $t = $t -replace '(?is)<style[^>]*>.*?</style>', ' '
    $t = $t -replace '(?i)<br\s*/?>', "`n"
    $t = $t -replace '(?i)</p>', "`n"
    $t = $t -replace '(?is)<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace '[ \t\u3000]+', ' '
    $t = $t -replace "(\r\n|\r|\n){3,}", "`n`n"

    return $t.Trim()
}

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

function UrlDecode {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return [System.Net.WebUtility]::UrlDecode($Text)
}

function Clean-TextAnswer {
    param([string]$Text)

    $value = [string](Strip-Html $Text)
    $value = $value.Replace([string][char]0xFF1A, ':')
    if ($value.Contains(':')) {
        $value = ($value -split ':', 2 | Select-Object -Last 1)
    }

    $openParen = [string][char]0xFF08
    $closeParen = [string][char]0xFF09
    $countChar = [string][char]0x5B57
    $textCount = [string][char]0x6587 + [char]0x5B57
    if ($value.EndsWith($closeParen)) {
        $openIndex = $value.LastIndexOf($openParen)
        if ($openIndex -ge 0) {
            $parenContent = $value.Substring($openIndex + 1, $value.Length - $openIndex - 2).Trim()
            $parenContent = Normalize-Digits $parenContent
            $parenContent = $parenContent.Replace($textCount, $countChar)
            if ($parenContent.EndsWith($countChar)) {
                $digitPart = $parenContent.Substring(0, $parenContent.Length - 1).Trim()
                if ($digitPart -match '^\d+$') {
                    $value = $value.Substring(0, $openIndex).TrimEnd()
                }
            }
        }
    }

    return $value.Trim()
}

function Normalize-KataCombo {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $allowedChars = @(
        [char]0x30A2,
        [char]0x30A4,
        [char]0x30A6,
        [char]0x30A8,
        [char]0x30AA,
        [char]0x30AB,
        [char]0x30AD,
        [char]0x30AF,
        [char]0x30B1,
        [char]0x30B3
    )
    $allowedText = ($allowedChars -join '')
    return ([regex]::Replace($Text, "[^$allowedText]", ''))
}

function Format-KataCombo {
    param([string]$Text)
    $combo = Normalize-KataCombo $Text
    if ([string]::IsNullOrWhiteSpace($combo)) { return "" }
    return (($combo.ToCharArray() | ForEach-Object { [string]$_ }) -join '・')
}

function Extract-KataComboFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    $normalized = Normalize-Digits $Text
    $parenMatches = [regex]::Matches($normalized, '[（\(][^）\)]*[アイウエオカキクケコ][^）\)]*[）\)]')
    foreach ($m in $parenMatches) {
        $combo = Normalize-KataCombo $m.Value
        if ($combo.Length -ge 1) { return $combo }
    }

    $inline = [regex]::Match($normalized, '[アイウエオカキクケコ](?:[・、,\s　]+[アイウエオカキクケコ]){1,}')
    if ($inline.Success) {
        $combo = Normalize-KataCombo $inline.Value
        if ($combo.Length -ge 1) { return $combo }
    }

    return ""
}

function Parse-ChoiceComboMap {
    param([string]$Line)

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Line)) { return $map }

    $normalized = Normalize-Digits $Line
    $work = $normalized
    $sepChars = @(
        '.', ':', ',', '/', '(', ')', '[', ']',
        [string][char]0xFF1A, [string][char]0xFF0E, [string][char]0x3001,
        [string][char]0x30FB, [string][char]0xFF0F,
        [string][char]0xFF08, [string][char]0xFF09,
        [string][char]0x3010, [string][char]0x3011
    )
    foreach ($sep in $sepChars) {
        $work = $work.Replace($sep, ' ')
    }
    $tokens = @($work -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $tok = [string]$tokens[$i]

        if ($tok -match '^(\d{1,2})([アイウエオカキクケコ]{2,5})$') {
            $idx = [int]$Matches[1]
            if ($idx -lt 1 -or $idx -gt 20) { continue }
            $combo = Normalize-KataCombo $Matches[2]
            if (-not [string]::IsNullOrWhiteSpace($combo)) {
                $map[$idx] = $combo
            }
            continue
        }

        if ($tok -notmatch '^\d{1,2}$') { continue }
        $idx = [int]$tok
        if ($idx -lt 1 -or $idx -gt 20) { continue }
        if (($i + 1) -ge $tokens.Count) { continue }

        $combo = Normalize-KataCombo ([string]$tokens[$i + 1])
        if ([string]::IsNullOrWhiteSpace($combo)) { continue }
        $map[$idx] = $combo
        $i++
    }

    return $map
}

function Parse-KataStatements {
    param([string[]]$Paragraphs)

    $items = @()
    foreach ($line in $Paragraphs) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        foreach ($part in ($line -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $m = [regex]::Match($part, '^\s*([アイウエオカキクケコ])[\s　\.．、,:：-]+(.+)$')
            if (-not $m.Success) { continue }
            $marker = $m.Groups[1].Value
            $text = $m.Groups[2].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $items += [PSCustomObject]@{ Marker = $marker; Text = $text }
        }
    }
    return $items
}

function Extract-KataStatementsFromText {
    param([string]$Text)

    $items = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $items }

    $patterns = @(
        '(?ms)(?:^|\n)\s*([アイウエオカキクケコ])[\s　\.．、,:：\-]+\s*(.+?)(?=(?:\n\s*[アイウエオカキクケコ][\s　\.．、,:：\-]+)|\z)',
        '(?ms)([アイウエオカキクケコ])[\s　\.．、,:：\-]+\s*(.+?)(?=(?:[\s　]*[アイウエオカキクケコ][\s　\.．、,:：\-]+)|\z)'
    )

    $regexHits = @()
    foreach ($pattern in $patterns) {
        $regexHits = [regex]::Matches($Text, $pattern)
        if ($regexHits.Count -gt 0) { break }
    }
    foreach ($m in $regexHits) {
        $marker = $m.Groups[1].Value
        $text = $m.Groups[2].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $items += [PSCustomObject]@{ Marker = $marker; Text = $text }
    }

    return $items
}

function Convert-ChoiceComboQuestionToComboOx {
    param([object]$Question)

    if ($null -eq $Question) { return $Question }
    if ($Question.answerType -ne 'choice') { return $Question }
    if (-not [string]::IsNullOrWhiteSpace($Question.questionText)) {
        $selectedIndex = [int]$Question.correctOption
        if ($selectedIndex -lt 1 -or $selectedIndex -gt @($Question.limbs).Count) { return $Question }

        $selectedText = [string]$Question.limbs[$selectedIndex - 1].text
        if (-not (Test-ComboOptionText $selectedText)) { return $Question }

        $statements = Extract-KataStatementsFromText $Question.questionText
        if ($statements.Count -lt 4) {
            $statements = Parse-KataStatements -Paragraphs @($Question.questionText -split '\r?\n')
        }
        if ($statements.Count -lt 4) { return $Question }

        $combo = Normalize-KataCombo $selectedText
        if ([string]::IsNullOrWhiteSpace($combo)) { return $Question }

        $newLimbs = @()
        $i = 0
        foreach ($st in $statements) {
            $marker = [string]$st.Marker
            if ([string]::IsNullOrWhiteSpace($marker)) { continue }
            $isCorrect = $combo.Contains($marker)
            $newLimbs += [PSCustomObject]@{
                id = "{0}-l{1}" -f $Question.id, $i
                text = [string]$st.Text
                correct = [bool]$isCorrect
                explanation = $Question.limbs | ForEach-Object { $_.explanation } | Select-Object -First 1
            }
            $i++
        }

        if ($newLimbs.Count -lt 4) { return $Question }

        return [PSCustomObject]@{
            id = $Question.id
            subject = $Question.subject
            category = $Question.category
            source = $Question.source
            questionText = $Question.questionText
            limbs = $newLimbs
            questionUrl = $Question.questionUrl
            correctOption = 0
            answerType = 'combo_ox'
        }
    }

    return $Question
}

function Test-ComboOptionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $compact = (Normalize-KataCombo $Text)
    if ([string]::IsNullOrWhiteSpace($compact)) { return $false }
    return ($compact -match '^[アイウエオカキクケコ]{2,5}$')
}

# 問題文からカタカナ肢（ア．イ．ウ．…）を「順序どおり」に抽出する。
# 行単位ではなく文字列全体を走査するため、「…有する。イ．…」のように
# 改行なしで連続するマーカーも正しく分割できる。
# 期待マーカー列 ア,イ,ウ,… を前から順に探し、各マーカー直後（区切り文字含む）から
# 次に見つかったマーカーの直前までを肢テキストとする。
function Extract-OrderedKataStatements {
    param([string]$Text)
    $items = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $items }

    $allMarkers = @(
        [char]0x30A2, [char]0x30A4, [char]0x30A6, [char]0x30A8, [char]0x30AA,  # ア イ ウ エ オ
        [char]0x30AB, [char]0x30AD, [char]0x30AF, [char]0x30B1, [char]0x30B3   # カ キ ク ケ コ
    )
    # リード文の「次のア～オ」「ア～エ」等で宣言された肢範囲を検出し、
    # 抽出対象マーカーを限定する（肢本文中の無関係なカタカナの過抽出を防ぐ）。
    $markers = $allMarkers
    $rangeRe = '([アイウエオカキクケコ])\s*[～〜~]\s*([アイウエオカキクケコ])'
    $head = ($Text -split '\r?\n')[0]
    $rangeMatch = [regex]::Match($head, $rangeRe)
    if (-not $rangeMatch.Success -and $Text.Length -gt 0) {
        $headLen = [Math]::Min(120, $Text.Length)
        $rangeMatch = [regex]::Match($Text.Substring(0, $headLen), $rangeRe)
    }
    if ($rangeMatch.Success) {
        $ia = [Array]::IndexOf($allMarkers, [char]$rangeMatch.Groups[1].Value[0])
        $ib = [Array]::IndexOf($allMarkers, [char]$rangeMatch.Groups[2].Value[0])
        if ($ia -ge 0 -and $ib -ge $ia) {
            $markers = $allMarkers[$ia..$ib]
        }
    }
    # マーカー直後に来る区切り文字（これが続く場合のみ肢ラベルと見なす）
    $sepClass = '[\s　\.．、]'

    # 各マーカーのラベル位置を順番に検出する
    $positions = New-Object System.Collections.ArrayList
    $searchFrom = 0
    foreach ($m in $markers) {
        $mk = [string]$m
        $found = -1
        $p = $searchFrom
        while ($p -lt $Text.Length) {
            $hit = $Text.IndexOf($mk, $p)
            if ($hit -lt 0) { break }
            $after = $hit + 1
            if ($after -lt $Text.Length -and [regex]::IsMatch([string]$Text[$after], $sepClass)) {
                $found = $hit
                break
            }
            $p = $hit + 1
        }
        if ($found -ge 0) {
            [void]$positions.Add([PSCustomObject]@{ Marker = $mk; LabelStart = $found })
            $searchFrom = $found + 1
        }
        # 見つからないマーカーはスキップして次のマーカーを探す
    }

    if ($positions.Count -lt 2) { return $items }

    for ($i = 0; $i -lt $positions.Count; $i++) {
        $labelStart = [int]$positions[$i].LabelStart
        # マーカー＋連続する区切り文字をスキップした位置が本文の開始
        $ts = $labelStart + 1
        while ($ts -lt $Text.Length -and [regex]::IsMatch([string]$Text[$ts], $sepClass)) { $ts++ }
        $end = if ($i + 1 -lt $positions.Count) { [int]$positions[$i + 1].LabelStart } else { $Text.Length }
        if ($end -le $ts) { continue }
        $stmt = $Text.Substring($ts, $end - $ts).Trim()
        if (-not [string]::IsNullOrWhiteSpace($stmt)) {
            $items += [PSCustomObject]@{ Marker = $positions[$i].Marker; Text = $stmt }
        }
    }
    return $items
}

# 問題文の「リード文」（最初のカタカナ肢ラベルより前の部分）だけを返す。
# combo_ox では各肢を個別に出題するため、questionText に肢本文を残さない。
function Get-LeadText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $markers = @(
        [char]0x30A2, [char]0x30A4, [char]0x30A6, [char]0x30A8, [char]0x30AA,
        [char]0x30AB, [char]0x30AD, [char]0x30AF, [char]0x30B1, [char]0x30B3
    )
    $sepClass = '[\s　\.．、]'

    $firstIdx = -1
    foreach ($m in $markers) {
        $mk = [string]$m
        $p = 0
        while ($p -lt $Text.Length) {
            $hit = $Text.IndexOf($mk, $p)
            if ($hit -lt 0) { break }
            $after = $hit + 1
            if ($after -lt $Text.Length -and [regex]::IsMatch([string]$Text[$after], $sepClass)) {
                if ($firstIdx -lt 0 -or $hit -lt $firstIdx) { $firstIdx = $hit }
                break
            }
            $p = $hit + 1
        }
    }
    if ($firstIdx -gt 0) {
        return $Text.Substring(0, $firstIdx).TrimEnd()
    }
    return $Text.TrimEnd()
}

# 「その正誤を正しく示す組合せはどれか」型の選択肢テキストから
# マーカー別の ○/× (true/false) マップを抽出する。
# 例: "ア○ イ× ウ○ エ×" → { ア=true, イ=false, ウ=true, エ=false }
# 抽出できなければ空の hashtable を返す。
function Parse-SogoOptionText {
    param([string]$OptionText)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($OptionText)) { return $map }

    $utf8 = [System.Text.Encoding]::UTF8
    $maruStr  = $utf8.GetString([byte[]]@(0xE2, 0x97, 0x8B))   # ○ U+25CB
    $batsuStr = $utf8.GetString([byte[]]@(0xC3, 0x97))          # × U+00D7
    $batsu2Str = $utf8.GetString([byte[]]@(0xE2, 0x9C, 0x95))  # ✕ U+2715
    $seStr    = $utf8.GetString([byte[]]@(0xE6, 0xAD, 0xA3))   # 正
    $goStr    = $utf8.GetString([byte[]]@(0xE8, 0xAA, 0xA4))   # 誤

    $markers = @(
        [char]0x30A2, [char]0x30A4, [char]0x30A6, [char]0x30A8, [char]0x30AA,
        [char]0x30AB, [char]0x30AD, [char]0x30AF, [char]0x30B1, [char]0x30B3
    )
    # マーカーと値の間に許容する区切り文字
    $sepCharsArr = @([char]0x20, [char]0x09, [char]0x3000, [char]0x2D, [char]0xFF1A,
                     [char]0x3A,  [char]0x20, [char]0xFF0E, [char]0x2E)

    foreach ($m in $markers) {
        $marker = [string]$m
        $idx = $OptionText.IndexOf($marker)
        if ($idx -lt 0) { continue }

        # マーカーの直後から区切り文字をスキップして判定値を探す
        $pos = $idx + 1
        while ($pos -lt $OptionText.Length) {
            $ch = $OptionText[$pos]
            if ($sepCharsArr -contains $ch) { $pos++; continue }
            break
        }
        if ($pos -ge $OptionText.Length) { continue }

        $rest = $OptionText.Substring($pos)
        if ($rest.StartsWith($maruStr) -or $rest.StartsWith('○')) {
            $map[$marker] = $true
        } elseif ($rest.StartsWith($batsuStr) -or $rest.StartsWith($batsu2Str) -or
                  $rest.StartsWith([string][char]0x00D7) -or $rest.StartsWith('x') -or $rest.StartsWith('X')) {
            $map[$marker] = $false
        } elseif ($rest.StartsWith($seStr)) {
            $map[$marker] = $true
        } elseif ($rest.StartsWith($goStr)) {
            $map[$marker] = $false
        }
    }
    return $map
}


function Get-YearKeyFromString {
    param([string]$InputText)

    $decoded = UrlDecode $InputText
    $decoded = Normalize-Digits $decoded

    $reiwa = [string]([char]0x4EE4) + [char]0x548C
    $heisei = [string]([char]0x5E73) + [char]0x6210
    $yearChar = [string][char]0x5E74
    $gannen = [string][char]0x5143

    # Reiwa: "令和7年" / "令和元年"
    $reiwaPattern = [regex]::Escape($reiwa) + "\s*(" + [regex]::Escape($gannen) + "|\d+)\s*" + [regex]::Escape($yearChar)
    $mR = [regex]::Match($decoded, $reiwaPattern)
    if ($mR.Success) {
        $n = if ($mR.Groups[1].Value -eq $gannen) { 1 } else { [int]$mR.Groups[1].Value }
        return "r$n"
    }

    # Heisei: "平成24年"
    $heiseiPattern = [regex]::Escape($heisei) + "\s*(\d+)\s*" + [regex]::Escape($yearChar)
    $mH = [regex]::Match($decoded, $heiseiPattern)
    if ($mH.Success) {
        return "h$([int]$mH.Groups[1].Value)"
    }

    return "unknown"
}

function Extract-YearLinks {
    param([string]$IndexHtml)

    $m = [regex]::Matches($IndexHtml, '(?is)<a\s+href="(https://gyosyo\.info/[^"]+/)"[^>]*>.*?</a>')
    $map = @{}

    foreach ($x in $m) {
        $url = ($x.Groups[1].Value -replace '\s+', '').Trim()
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        $u = $url.ToLower()
        if ($u -notlike '*%e5%b9%b4%e5%ba%a6*') { continue }   # contains "年度"
        if ($u -notlike '*%e8%a7%a3%e8%aa%ac*') { continue }   # contains "解説"
        if ($u -notlike '*%e8%a1%8c%e6%94%bf%e6%9b%b8%e5%a3%ab*') { continue }

        $map[$url] = $true
    }

    $years = @()
    foreach ($k in $map.Keys) {
        $years += [PSCustomObject]@{ Url = $k; Key = Get-YearKeyFromString $k }
    }

    return $years | Sort-Object Url
}

function Extract-QuestionLinks {
    param([string]$YearHtml)

    $m = [regex]::Matches($YearHtml, '(?is)<a\s+href="(https://gyosyo\.info/[^"]+)"[^>]*>.*?</a>')

    $seen = @{}
    $items = @()

    foreach ($x in $m) {
        $url = ($x.Groups[1].Value -replace '\s+', '').Trim()
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if (-not $url.EndsWith('/')) { $url = "$url/" }

        $decoded = Normalize-Digits (UrlDecode $url)
        $qChar = [string][char]0x554F
        $qPattern = [regex]::Escape($qChar) + "\s*(\d+)"
        $qMatch = [regex]::Match($decoded, $qPattern)
        if (-not $qMatch.Success) { continue }

        $qNo = [int]$qMatch.Groups[1].Value
        if ($qNo -lt 1 -or $qNo -gt 100) { continue }

        if ($seen.ContainsKey($url)) { continue }
        $seen[$url] = $true

        $anchorText = Strip-Html $x.Value
        $items += [PSCustomObject]@{
            Url = $url
            Number = $qNo
            Category = $anchorText
        }
    }

    return $items | Sort-Object Number, Url
}

function Extract-QuestionPayload {
    param(
        [string]$Html,
        [string]$QuestionUrl,
        [string]$FallbackCategory
    )

    $titleMatch = [regex]::Match($Html, '(?is)<h1[^>]*class="post-title"[^>]*>(.*?)</h1>')
    $title = if ($titleMatch.Success) { Strip-Html $titleMatch.Groups[1].Value } else { "" }

    $sectionMatch = [regex]::Match($Html, '(?is)<section\s+class="post-content"[^>]*>(.*?)</section>')
    if (-not $sectionMatch.Success) { throw "post-content not found: $QuestionUrl" }
    $section = $sectionMatch.Groups[1].Value

    $toiMatch = [regex]::Match($section, '(?is)<div\s+id="toi"[^>]*>(.*?)<div\s+id="kaitou"')
    $toiHtml = ""
    if ($toiMatch.Success) {
        $toiHtml = $toiMatch.Groups[1].Value
    } else {
        # Old pages may not have div#toi. In that case, treat the content before div#kaitou as the question block.
        $toiFallback = [regex]::Match($section, '(?is)^(.*?)(?:<div\s+id="kaitou"|<a\s+name="kotae")')
        if (-not $toiFallback.Success) { throw "toi block not found: $QuestionUrl" }
        $toiHtml = $toiFallback.Groups[1].Value
    }

    $questionParagraphs = @()
    $pMatches = [regex]::Matches($toiHtml, '(?is)<p[^>]*>(.*?)</p>')
    foreach ($p in $pMatches) {
        $inner = $p.Groups[1].Value
        # skip jump link to answer block
        if ($inner -match '(?i)href\s*=\s*"#kotae"') { continue }

        $txt = Strip-Html $inner
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        $questionParagraphs += $txt
    }

    # Some pages place the question stem directly in the block body instead of wrapping it in <p> tags.
    # In that case, capture the leading prose before the first option list or answer link.
    if ($questionParagraphs.Count -eq 0) {
        $leadMatch = [regex]::Match($toiHtml, '(?is)^(.*?)(?=<(?:ul|ol|div\s+id="kaitou"|a\s+name="kotae")|\z)')
        if ($leadMatch.Success) {
            $leadText = Strip-Html $leadMatch.Groups[1].Value
            if (-not [string]::IsNullOrWhiteSpace($leadText)) {
                $questionParagraphs += $leadText
            }
        }
    }

    if ($questionParagraphs.Count -eq 0) {
        $fallbackText = Strip-Html $toiHtml
        if (-not [string]::IsNullOrWhiteSpace($fallbackText)) {
            $questionParagraphs += $fallbackText
        }
    }

    $questionText = ($questionParagraphs -join "`n").Trim()
    $questionText = $questionText -replace '\\r\\n', "`n"
    $questionText = $questionText -replace '\\n', "`n"

    # 問題文末尾の（注）以降の注記ブロックを除去する
    $chuuFull = [string][char]0xFF08 + [char]0x6CE8 + [char]0xFF09   # （注）
    $chuuHalf = '(' + [char]0x6CE8 + ')'                              # (注)
    foreach ($chuuMarker in @($chuuFull, $chuuHalf)) {
        $chuuIdx = $questionText.IndexOf($chuuMarker)
        if ($chuuIdx -gt 0) {
            $questionText = $questionText.Substring(0, $chuuIdx).TrimEnd()
            break
        }
    }

    $comboChoiceMap = @{}
    foreach ($line in $questionParagraphs) {
        $map = Parse-ChoiceComboMap -Line $line
        if ($map.Count -ge 2) {
            $comboChoiceMap = $map
            break
        }
    }

    $kataStatements = @()
    $kataMarkersSet = @(
        [string][char]0x30A2,
        [string][char]0x30A4,
        [string][char]0x30A6,
        [string][char]0x30A8,
        [string][char]0x30AA,
        [string][char]0x30AB,
        [string][char]0x30AD,
        [string][char]0x30AF,
        [string][char]0x30B1,
        [string][char]0x30B3
    )
    $statementTrimChars = @(
        [char]0x20,
        [char]0x3000,
        [char]0x2E,
        [char]0xFF0E,
        [char]0x3001,
        [char]0x2C,
        [char]0x3A,
        [char]0xFF1A,
        [char]0x2D,
        [char]0x30FB
    )
    foreach ($line in $questionParagraphs) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmedLine = $line.Trim()
        if ($trimmedLine.Length -lt 3) { continue }
        $marker = [string]$trimmedLine[0]
        if ($kataMarkersSet -notcontains $marker) { continue }
        $text = $trimmedLine.Substring(1).TrimStart($statementTrimChars)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $kataStatements += [PSCustomObject]@{ Marker = $marker; Text = $text }
        }
    }
    if ($kataStatements.Count -lt 4 -and -not [string]::IsNullOrWhiteSpace($questionText)) {
        foreach ($line in @($questionText -split '\r?\n')) {
            $trimmedLine = $line.Trim()
            if ($trimmedLine.Length -lt 3) { continue }
            $marker = [string]$trimmedLine[0]
            if ($kataMarkersSet -notcontains $marker) { continue }
            $text = $trimmedLine.Substring(1).TrimStart($statementTrimChars)
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $kataStatements += [PSCustomObject]@{ Marker = $marker; Text = $text }
            }
        }
    }
    $isInvertedComboQuestion = Test-IsInvertedQuestion $questionText

    # options are li tags in the question block
    $optionTexts = @()
    $liMatches = [regex]::Matches($toiHtml, '(?is)<li[^>]*>(.*?)</li>')
    foreach ($li in $liMatches) {
        $txt = Strip-Html $li.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        if ($txt.Length -lt 2) { continue }
        $optionTexts += $txt
    }

    if ($optionTexts.Count -eq 0 -and $comboChoiceMap.Count -gt 0) {
        $orderedKeys = @($comboChoiceMap.Keys | Sort-Object)
        foreach ($k in $orderedKeys) {
            $optionTexts += (Format-KataCombo $comboChoiceMap[$k])
        }
    }

    # answer block: multiple-choice pages use numeric answer, descriptive pages use text answer
    $answerNumber = 0
    $answerText = ""
    $acceptedAnswerTexts = @()
    $explanation = ""
    $answerRawForCombo = ""
    $ansBlock = [regex]::Match($section, '(?is)<div\s+id="kaitou"[^>]*>(.*?)</div>')
    if ($ansBlock.Success) {
        $answerBlockHtml = $ansBlock.Groups[1].Value
        $answerSectionHtml = $answerBlockHtml
        $explanationHtml = ""

        $explanationMarker = [string][char]0x3010 + [char]0x89E3 + [char]0x8AAC + [char]0x3011
        $answerParts = [regex]::Split($answerBlockHtml, [regex]::Escape($explanationMarker), 2)
        if ($answerParts.Count -ge 2) {
            $answerSectionHtml = $answerParts[0]
            $explanationHtml = $answerParts[1]
        }

        $answerStrong = [regex]::Match($answerSectionHtml, '(?is)<strong[^>]*>(.*?)</strong>')
        if ($answerStrong.Success) {
            $answerRaw = Strip-Html $answerStrong.Groups[1].Value
            $answerRaw = Normalize-Digits $answerRaw
            $answerRaw = $answerRaw.Replace([string][char]0xFF1A, ':')
            $answerValue = if ($answerRaw.Contains(':')) { ($answerRaw -split ':', 2 | Select-Object -Last 1).Trim() } else { $answerRaw.Trim() }
            $answerRawForCombo = $answerRaw
            $ansMatch = [regex]::Match($answerValue, '^\s*([0-9]+)')
            if ($ansMatch.Success) {
                $answerNumber = [int]$ansMatch.Groups[1].Value
            } else {
                $cleanStrongAnswer = Clean-TextAnswer $answerRaw
                if (-not [string]::IsNullOrWhiteSpace($cleanStrongAnswer)) {
                    $acceptedAnswerTexts += $cleanStrongAnswer
                }
            }
        }

        $paragraphMatches = [regex]::Matches($answerSectionHtml, '(?is)<p[^>]*>(.*?)</p>')
        foreach ($paragraphMatch in $paragraphMatches) {
            $candidateAnswer = Clean-TextAnswer $paragraphMatch.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($candidateAnswer)) { continue }
            if ($acceptedAnswerTexts -contains $candidateAnswer) { continue }
            $acceptedAnswerTexts += $candidateAnswer
        }

        if ($acceptedAnswerTexts.Count -gt 0) {
            $answerText = $acceptedAnswerTexts[0]
        }

        if (-not [string]::IsNullOrWhiteSpace($explanationHtml)) {
            $rawExp = [regex]::Replace($explanationHtml, '(?is)<div\s+align="center".*$', '')
            $explanation = Strip-Html $rawExp
        }
    }

    $answerCombo = Extract-KataComboFromText ($answerRawForCombo + " " + ($acceptedAnswerTexts -join " "))

    if ($answerNumber -eq 0 -and $comboChoiceMap.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($answerCombo)) {
        $orderedKeys = @($comboChoiceMap.Keys | Sort-Object)
        foreach ($k in $orderedKeys) {
            if ((Normalize-KataCombo $comboChoiceMap[$k]) -eq $answerCombo) {
                $answerNumber = [int]$k
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($answerCombo) -and $answerNumber -gt 0 -and $answerNumber -le $optionTexts.Count -and (Test-ComboOptionText $optionTexts[$answerNumber - 1])) {
        $answerCombo = Normalize-KataCombo $optionTexts[$answerNumber - 1]
    }

    $comboOptionList = $false
    if ($optionTexts.Count -gt 0) {
        $comboOptionList = $true
        foreach ($opt in $optionTexts) {
            if (-not (Test-ComboOptionText $opt)) {
                $comboOptionList = $false
                break
            }
        }
    }

    $answerType = 'choice'
    $comboOxFallback = $false
    if ($kataStatements.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($answerCombo) -and ($optionTexts.Count -eq 0 -or $comboOptionList)) {
        $comboOxFallback = $true
        $answerType = 'combo_ox'
    } elseif ($optionTexts.Count -eq 0) {
        if ([string]::IsNullOrWhiteSpace($answerText)) {
            throw "no options found: $QuestionUrl"
        } else {
            $answerType = 'text'
        }
    } elseif ($answerNumber -lt 1 -or $answerNumber -gt $optionTexts.Count) {
        # Some legacy pages intentionally provide non-numeric answers (e.g., "妥当な選択肢なし").
        if (-not [string]::IsNullOrWhiteSpace($answerText)) {
            $answerType = 'text'
        } else {
            throw "invalid answer number ($answerNumber): $QuestionUrl"
        }
    }

    $titleNorm = Normalize-Digits $title
    $qChar = [string][char]0x554F
    $qPattern = [regex]::Escape($qChar) + "\s*(\d+)"
    $mQ = [regex]::Match($titleNorm, $qPattern)
    $questionNo = if ($mQ.Success) { [int]$mQ.Groups[1].Value } else { 0 }

    $category = $FallbackCategory
    if ([string]::IsNullOrWhiteSpace($category)) {
        $fullWidthBar = [string][char]0xFF5C
        $parts = $title -split [regex]::Escape($fullWidthBar)
        if ($parts.Count -ge 3) {
            $category = $parts[2].Trim()
        }
    }

    return [PSCustomObject]@{
        Title = $title
        QuestionNo = $questionNo
        Category = $category
        QuestionText = $questionText
        AnswerType = $answerType
        Options = $optionTexts
        AnswerNumber = $answerNumber
        AnswerText = $answerText
        AcceptedAnswerTexts = $acceptedAnswerTexts
        Explanation = $explanation
        ComboOxFallback = $comboOxFallback
        ComboAnswer = $answerCombo
        ComboIsInverted = $isInvertedComboQuestion
        CombinationStatements = $kataStatements
    }
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

Write-Host "[1/4] Fetch year index"
$indexHtml = Get-Html -Url $IndexUrl
$allYearLinks = Extract-YearLinks -IndexHtml $indexHtml
if ($allYearLinks.Count -eq 0) { throw "no year links" }

$targetYears = @()
if ($All -or [string]::IsNullOrWhiteSpace($Year)) {
    $targetYears = $allYearLinks
} else {
    $y = $Year.ToLower().Trim()
    foreach ($link in $allYearLinks) {
        if ($link.Key -eq $y) {
            $targetYears += $link
        }
    }
}

if ($targetYears.Count -eq 0) { throw "target year not found: $Year" }

$allQuestions = @()

foreach ($yearItem in $targetYears) {
    Write-Host ""
    Write-Host ("[2/4] Year page: {0}" -f $yearItem.Url)

    $yearHtml = Get-Html -Url $yearItem.Url
    $questionLinks = Extract-QuestionLinks -YearHtml $yearHtml

    if ($questionLinks.Count -eq 0) {
        Write-Warning "No question links: $($yearItem.Url)"
        continue
    }

    Write-Host "  -> links: $($questionLinks.Count)"

    $yearQuestions = @()
    $yearKey = if ($yearItem.Key -and $yearItem.Key -ne "unknown") { $yearItem.Key } else { Get-YearKeyFromString $yearItem.Url }
    $prefix = if ($yearKey -ne "unknown") { $yearKey.ToUpper() } else { "GYOSYO" }

    foreach ($q in $questionLinks) {
        if ($q.Number -lt $StartQuestion -or $q.Number -gt $EndQuestion) { continue }

        Write-Host "[3/4] Q$($q.Number)"

        try {
            $qHtml = Get-Html -Url $q.Url
            $payload = Extract-QuestionPayload -Html $qHtml -QuestionUrl $q.Url -FallbackCategory $q.Category

            # 採番はページタイトルの「問N」を優先する。年度ページのリンクURLが
            # 別問題を指している場合（例: 問13ページのURLが問18を指す）でも、
            # ページ自身が宣言する問番号で採番するため、IDの重複・取り違えを防ぐ。
            # タイトルから問番号を取得できない場合のみURL由来の番号にフォールバックする。
            $questionNumber = if ($payload.QuestionNo -ge 1 -and $payload.QuestionNo -le 100) {
                [int]$payload.QuestionNo
            } else {
                [int]$q.Number
            }
            if ($payload.QuestionNo -ge 1 -and [int]$payload.QuestionNo -ne [int]$q.Number) {
                Write-Warning ("問番号の不一致: URL={0} タイトル={1} -> タイトルを採用 ({2})" -f $q.Number, $payload.QuestionNo, $q.Url)
            }
            $qid = "${prefix}-$questionNumber"
            $limbs = @()
            $comboOptionList = ($payload.Options.Count -gt 0) -and (@($payload.Options | Where-Object { Test-ComboOptionText $_ }).Count -eq $payload.Options.Count)
            # 肢抽出は順序付き走査を最優先する（改行なしで連続するマーカーも分割可能）。
            $statementItems = @(Extract-OrderedKataStatements $payload.QuestionText)
            # 順序付き抽出が空のときのみ従来ロジックにフォールバックする
            # （順序付き抽出が取れている場合に重複だらけのフォールバックで上書きしない）。
            if ($statementItems.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($payload.QuestionText)) {
                $fallbackItems = @($payload.CombinationStatements)
                if ($fallbackItems.Count -lt 4) {
                    $fallbackItems = @()
                    $statementPatterns = @(
                        '(?ms)(?:^|\n)\s*([アイウエオカキクケコ])[\s　\.．、,:：\-]+\s*(.+?)(?=(?:\n\s*[アイウエオカキクケコ][\s　\.．、,:：\-]+)|\z)',
                        '(?ms)([アイウエオカキクケコ])[\s　\.．、,:：\-]+\s*(.+?)(?=(?:[\s　]*[アイウエオカキクケコ][\s　\.．、,:：\-]+)|\z)'
                    )
                    foreach ($statementPattern in $statementPatterns) {
                        $statementMatches = [regex]::Matches($payload.QuestionText, $statementPattern)
                        foreach ($statementMatch in $statementMatches) {
                            $fallbackItems += [PSCustomObject]@{
                                Marker = $statementMatch.Groups[1].Value
                                Text = $statementMatch.Groups[2].Value.Trim()
                            }
                        }
                        if ($fallbackItems.Count -ge 4) { break }
                    }
                }
                $statementItems = $fallbackItems
            }
            # 同一肢テキストの重複を除去する（フォールバックや原文の重複に備える）。
            if ($statementItems.Count -gt 1) {
                $seenStatementText = @{}
                $dedupItems = @()
                foreach ($si in $statementItems) {
                    $key = ([string]$si.Text).Trim()
                    if ([string]::IsNullOrWhiteSpace($key)) { continue }
                    if ($seenStatementText.ContainsKey($key)) { continue }
                    $seenStatementText[$key] = $true
                    $dedupItems += $si
                }
                $statementItems = $dedupItems
            }

            # combo_ox への昇格条件:
            #   1. 元々 combo_ox か、または AnswerType=choice でカタカナ文が4つ以上ある
            #   2. かつ、正解選択肢テキストがカタカナコンボ形式（ア・イ・ウ など）であること
            # 条件 2 を加えることで「いくつあるか」「年代順」「略語の組合せ」等を
            # 誤って combo_ox と判定するのを防ぐ。
            $selectedOptionText = if ($payload.AnswerNumber -ge 1 -and $payload.AnswerNumber -le $payload.Options.Count) {
                [string]$payload.Options[$payload.AnswerNumber - 1]
            } else { "" }
            $useComboOx = ($payload.AnswerType -eq 'choice' -and $statementItems.Count -ge 4 -and $payload.AnswerNumber -gt 0 -and (Test-ComboOptionText $selectedOptionText))

            $resolvedAnswerType = $payload.AnswerType

            if ($payload.AnswerType -eq 'combo_ox' -or $useComboOx) {
                $comboSource = if ($payload.AnswerType -eq 'combo_ox' -and -not [string]::IsNullOrWhiteSpace($payload.ComboAnswer)) { $payload.ComboAnswer } else { ([string]$payload.Options[$payload.AnswerNumber - 1]) }
                $combo = Normalize-KataCombo $comboSource
                $isInverted = ([bool]$payload.ComboIsInverted) -or (Test-IsInvertedQuestion $payload.QuestionText)
                # 通常は4肢以上だが、出典側で1肢欠落する等2～3肢のケースも実在するため
                # 2肢未満のときのみ抽出失敗とみなして空にする。
                if ($statementItems.Count -lt 2) { $statementItems = @() }

                # 「その正誤を正しく示す組合せ」型: 選択肢に ○/× が含まれるか試みる
                $sogoMap = Parse-SogoOptionText $comboSource

                # 全マーカーがコンボに含まれる場合は「年代順」「組合せ」等の非標準型
                # ただし sogoMap がある場合は正誤を正しく示す組合せ型なのでそちらで処理
                $allMarkersPresent = ($statementItems.Count -gt 0) -and ($combo.Length -ge $statementItems.Count)

                if ($sogoMap.Count -ge 2) {
                    # 正誤を正しく示す組合せ型 — 各マーカーの ○/× から直接正誤を決定
                    $resolvedAnswerType = 'combo_ox'
                    for ($i = 0; $i -lt $statementItems.Count; $i++) {
                        $marker = [string]$statementItems[$i].Marker
                        $isCorrect = if ($sogoMap.ContainsKey($marker)) { [bool]$sogoMap[$marker] } else { $false }
                        if ($isInverted) { $isCorrect = -not $isCorrect }
                        $limbs += [PSCustomObject]@{
                            id = "${qid}-l$i"
                            text = [string]$statementItems[$i].Text
                            correct = [bool]$isCorrect
                            explanation = $payload.Explanation
                        }
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($combo) -and -not $allMarkersPresent) {
                    # 通常のカタカナコンボ型（正解コンボが全マーカーの真部分集合）
                    $resolvedAnswerType = 'combo_ox'
                    for ($i = 0; $i -lt $statementItems.Count; $i++) {
                        $marker = [string]$statementItems[$i].Marker
                        $contains = $combo.Contains($marker)
                        $isCorrect = if ($isInverted) { -not $contains } else { $contains }
                        $limbs += [PSCustomObject]@{
                            id = "${qid}-l$i"
                            text = [string]$statementItems[$i].Text
                            correct = [bool]$isCorrect
                            explanation = $payload.Explanation
                        }
                    }
                } else {
                    # コンボ抽出失敗 or 全マーカー一致（年代順・略語組合せ等）→ choice として処理
                    $resolvedAnswerType = 'choice'
                    $isChoiceInverted = ([bool]$payload.ComboIsInverted) -or (Test-IsInvertedQuestion $payload.QuestionText)
                    for ($i = 0; $i -lt $payload.Options.Count; $i++) {
                        $idx2 = $i + 1
                        $isSelected = ($idx2 -eq $payload.AnswerNumber)
                        $isStatementTrue = if ($isChoiceInverted) { -not $isSelected } else { $isSelected }
                        $limbs += [PSCustomObject]@{
                            id = "${qid}-l$i"
                            text = $payload.Options[$i]
                            correct = [bool]$isStatementTrue
                            explanation = $payload.Explanation
                        }
                    }
                }
            } elseif ($payload.AnswerType -eq 'text') {
                $resolvedAnswerType = 'text'
                $limbs += [PSCustomObject]@{
                    id = "${qid}-l0"
                    text = 'Answer in free text.'
                    correct = $true
                    correctText = $payload.AnswerText
                    acceptedAnswers = @($payload.AcceptedAnswerTexts)
                    explanation = $payload.Explanation
                }
            } else {
                $resolvedAnswerType = 'choice'
                $isChoiceInverted = ([bool]$payload.ComboIsInverted) -or (Test-IsInvertedQuestion $payload.QuestionText)
                for ($i = 0; $i -lt $payload.Options.Count; $i++) {
                    $idx2 = $i + 1
                    $isSelected = ($idx2 -eq $payload.AnswerNumber)
                    $isStatementTrue = if ($isChoiceInverted) { -not $isSelected } else { $isSelected }
                    $limbs += [PSCustomObject]@{
                        id = "${qid}-l$i"
                        text = $payload.Options[$i]
                        correct = [bool]$isStatementTrue
                        explanation = $payload.Explanation
                    }
                }
            }

            # combo_ox では各肢を個別に出題するため、questionText はリード文のみにする
            # （肢本文 ア．イ．… を二重に含めない）。それ以外（choice・text・
            # 「いくつあるか」等）は ア～オ が判断対象の本文なのでそのまま保持する。
            $finalQuestionText = if ($resolvedAnswerType -eq 'combo_ox') {
                Get-LeadText $payload.QuestionText
            } else {
                $payload.QuestionText
            }

            $questionObject = [PSCustomObject]@{
                id = $qid
                subject = ([string]([char]0x884C) + [char]0x653F + [char]0x66F8 + [char]0x58EB)
                category = $payload.Category
                source = $payload.Title
                questionText = $finalQuestionText
                limbs = $limbs
                questionUrl = $q.Url
                correctOption = $payload.AnswerNumber
                answerType = $resolvedAnswerType
            }
            $yearQuestions += $questionObject
        } catch {
            Write-Warning "Skip Q$($q.Number): $($_.Exception.Message)"
        }

        Start-Sleep -Milliseconds 500
    }

    if ($yearQuestions.Count -eq 0) {
        Write-Warning "No extracted questions for: $($yearItem.Url)"
        continue
    }

    $yearOutFile = Join-Path (Resolve-Path $OutDir).Path ("gyosyo_{0}_questions.json" -f $yearKey)
    [System.IO.File]::WriteAllText($yearOutFile, (ConvertTo-Json -Depth 10 -InputObject @($yearQuestions)), [System.Text.Encoding]::UTF8)
    Write-Host "[4/4] Saved: $yearOutFile ($($yearQuestions.Count))"

    $allQuestions += $yearQuestions
}

if ($allQuestions.Count -gt 0) {
    $allFile = Join-Path (Resolve-Path $OutDir).Path "gyosyo_all_questions.json"
    $legacyAllFile = Join-Path (Resolve-Path $OutDir).Path "all_questions.json"
    [System.IO.File]::WriteAllText($allFile, (ConvertTo-Json -Depth 10 -InputObject @($allQuestions)), [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($legacyAllFile, (ConvertTo-Json -Depth 10 -InputObject @($allQuestions)), [System.Text.Encoding]::UTF8)
    Write-Host ""
    Write-Host ("Total extracted: {0}" -f $allQuestions.Count)
    Write-Host ("Merged file: {0}" -f $allFile)
} else {
    Write-Warning "No questions extracted."
}
