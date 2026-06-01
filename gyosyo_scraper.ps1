param(
    [string]$IndexUrl = "https://gyosyo.info/%E8%A1%8C%E6%94%BF%E6%9B%B8%E5%A3%AB%E3%81%AE%E9%81%8E%E5%8E%BB%E5%95%8F%E9%9B%86%EF%BC%88%E5%95%8F%E9%A1%8C%E3%81%A8%E8%A7%A3%E8%AA%AC%EF%BC%89/",
    [string]$OutDir = ".\\output",
    [string]$Year = "",
    [int]$StartQuestion = 1,
    [int]$EndQuestion = 60,
    [switch]$All,
    [switch]$OfflineMergeOnly
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36"
}

function Get-Html {
    param([string]$Url)
    $resp = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 40
    return [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
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
    return ([regex]::Replace($Text, '[^アイウエオカキクケコ]', ''))
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
        $m = [regex]::Match($line, '^\s*([アイウエオカキクケコ])[\s　\.．、,:：-]+(.+)$')
        if (-not $m.Success) { continue }
        $marker = $m.Groups[1].Value
        $text = $m.Groups[2].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $items += [PSCustomObject]@{ Marker = $marker; Text = $text }
    }
    return $items
}

function Merge-LocalOutputFiles {
    param([string]$TargetOutDir)

    if (-not (Test-Path $TargetOutDir)) {
        throw "output directory not found: $TargetOutDir"
    }

    $resolvedOutDir = (Resolve-Path $TargetOutDir).Path
    $yearFiles = @(Get-ChildItem -LiteralPath $resolvedOutDir -Filter 'gyosyo_*_questions.json' -File |
        Where-Object { $_.Name -ne 'gyosyo_all_questions.json' } |
        Sort-Object Name)

    if ($yearFiles.Count -eq 0) {
        throw "no per-year files found under: $resolvedOutDir"
    }

    $jsonBodies = @()
    foreach ($f in $yearFiles) {
        $raw = [string](Get-Content -Raw -LiteralPath $f.FullName)
        $trimmed = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
            throw "invalid JSON array file: $($f.FullName)"
        }

        $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
        if (-not [string]::IsNullOrWhiteSpace($inner)) {
            $jsonBodies += $inner
        }
    }

    if ($jsonBodies.Count -eq 0) {
        throw "no questions found in local per-year files"
    }

    $json = "[" + [Environment]::NewLine + ($jsonBodies -join ("," + [Environment]::NewLine)) + [Environment]::NewLine + "]"
    $mergedFile = Join-Path $resolvedOutDir 'gyosyo_all_questions.json'
    $appFile = Join-Path $resolvedOutDir 'all_questions.json'

    [System.IO.File]::WriteAllText($mergedFile, $json, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($appFile, $json, [System.Text.Encoding]::UTF8)

    Write-Host "[offline] merged from local files: $($yearFiles.Count)"
    Write-Host "[offline] merged items from non-empty files: $($jsonBodies.Count)"
    Write-Host "[offline] wrote: $mergedFile"
    Write-Host "[offline] wrote: $appFile"
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
    $questionText = ($questionParagraphs -join "`n").Trim()

    $comboChoiceMap = @{}
    foreach ($line in $questionParagraphs) {
        $map = Parse-ChoiceComboMap -Line $line
        if ($map.Count -ge 2) {
            $comboChoiceMap = $map
            break
        }
    }

    $kataStatements = Parse-KataStatements -Paragraphs $questionParagraphs
    $isInvertedComboQuestion = $questionText -match '誤っているもの|妥当でないもの|適切でないもの|誤りであるもの|誤りはどれか'

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

    $answerType = 'choice'
    $comboOxFallback = $false
    if ($optionTexts.Count -eq 0) {
        if ($kataStatements.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($answerCombo)) {
            $comboOxFallback = $true
            $answerType = 'combo_ox'
        } elseif ([string]::IsNullOrWhiteSpace($answerText)) {
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

if ($OfflineMergeOnly) {
    Merge-LocalOutputFiles -TargetOutDir $OutDir
    return
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

            $qid = "${prefix}-$($q.Number)"
            $limbs = @()
            if ($payload.AnswerType -eq 'combo_ox') {
                $combo = Normalize-KataCombo $payload.ComboAnswer
                $isInverted = [bool]$payload.ComboIsInverted
                for ($i = 0; $i -lt $payload.CombinationStatements.Count; $i++) {
                    $st = $payload.CombinationStatements[$i]
                    $marker = [string]$st.Marker
                    $contains = $combo.Contains($marker)
                    $isCorrect = if ($isInverted) { -not $contains } else { $contains }
                    $limbs += [PSCustomObject]@{
                        id = "${qid}-l$i"
                        text = [string]$st.Text
                        correct = [bool]$isCorrect
                        explanation = $payload.Explanation
                    }
                }
            } elseif ($payload.AnswerType -eq 'text') {
                $limbs += [PSCustomObject]@{
                    id = "${qid}-l0"
                    text = 'Answer in free text.'
                    correct = $true
                    correctText = $payload.AnswerText
                    acceptedAnswers = @($payload.AcceptedAnswerTexts)
                    explanation = $payload.Explanation
                }
            } else {
                for ($i = 0; $i -lt $payload.Options.Count; $i++) {
                    $idx = $i + 1
                    $limbs += [PSCustomObject]@{
                        id = "${qid}-l$i"
                        text = $payload.Options[$i]
                        correct = ($idx -eq $payload.AnswerNumber)
                        explanation = $payload.Explanation
                    }
                }
            }

            $yearQuestions += [PSCustomObject]@{
                id = $qid
                subject = "行政書士"
                category = $payload.Category
                source = $payload.Title
                questionText = $payload.QuestionText
                limbs = $limbs
                questionUrl = $q.Url
                correctOption = $payload.AnswerNumber
                answerType = $payload.AnswerType
            }
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
    [System.IO.File]::WriteAllText($allFile, (ConvertTo-Json -Depth 10 -InputObject @($allQuestions)), [System.Text.Encoding]::UTF8)
    Write-Host ""
    Write-Host ("Total extracted: {0}" -f $allQuestions.Count)
    Write-Host ("Merged file: {0}" -f $allFile)
} else {
    Write-Warning "No questions extracted."
}
