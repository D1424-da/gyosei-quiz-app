# ==================================================================
# Chisatsu Scraper - Nishio Shinichi Office
# URL: https://www.nishio-shinichi-office.com/
# Usage (single year):
#   powershell -ExecutionPolicy Bypass -File .\scraper.ps1 -Year r7 -Start 1 -End 20
#   powershell -ExecutionPolicy Bypass -File .\scraper.ps1 -Year h17 -Start 1 -End 20
# Usage (all years H17-R7):
#   powershell -ExecutionPolicy Bypass -File .\scraper.ps1 -All
# ==================================================================

param(
    [string]$Year   = "",
    [int]   $Start  = 1,
    [int]   $End    = 20,
    [string]$OutDir = ".\output",
    [switch]$All           # scrape all years H17-R7 into one JSON
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# --------------------------------------------------------------
# Build Japanese character sets from Unicode code points
# (avoids encoding issues with regex literals)
# --------------------------------------------------------------
# Katakana markers: ア〜コ
$cA = [char]0x30A2; $cI = [char]0x30A4; $cU = [char]0x30A6
$cE = [char]0x30A8; $cO = [char]0x30AA
$cKa = [char]0x30AB; $cKi = [char]0x30AD; $cKu = [char]0x30AF
$cKe = [char]0x30B1; $cKo = [char]0x30B3
$kataMarkers = @($cA,$cI,$cU,$cE,$cO,$cKa,$cKi,$cKu,$cKe,$cKo)
$kataMarkerClassText = ($kataMarkers -join '')
$kataClass  = "[$kataMarkerClassText]"                           # [アイウエオカキクケコ]
$kataStart        = "^$kataClass"                                # starts with katakana marker directly
$kataPrefixStart  = "^.{1,15}[；：;]$kataClass[\s\t\u3000]"      # e.g. 学生；ア　text or 学生：ア　text

# Full-width digits: FF11-FF15 (answer option numbers)
$d = @(); 0xFF11..0xFF15 | ForEach-Object { $d += [char]$_ } # 1-5
$fwClass = "[$($d -join '')]"                                 # [１２３４５]

# Common path segment 1 (encoded):  土地家屋調査士試験過去問-解説-無料
$p1 = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93%E9%81%8E%E5%8E%BB%E5%95%8F-%E8%A7%A3%E8%AA%AC-%E7%84%A1%E6%96%99"

# URL segment 2 (year directory) — verified from browser for each year
# Reiwa: 土地家屋調査士試験-令和-{X}年度 or 令和{X}年度
# Heisei: 土地家屋調査士試験-平成{XX}年度
$yearDirMap = @{
    # --- Reiwa ---
    "r7"  = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E4%BB%A4%E5%92%8C-%EF%BC%97%E5%B9%B4%E5%BA%A6"
    "r6"  = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E4%BB%A4%E5%92%8C-%EF%BC%96%E5%B9%B4%E5%BA%A6"
    "r5"  = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E4%BB%A4%E5%92%8C%EF%BC%95%E5%B9%B4%E5%BA%A6"
    "r4"  = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E4%BB%A4%E5%92%8C%EF%BC%94%E5%B9%B4%E5%BA%A6"
    "r3"  = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E4%BB%A4%E5%92%8C%EF%BC%93%E5%B9%B4%E5%BA%A6"
    "r2"  = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E4%BB%A4%E5%92%8C%EF%BC%92%E5%B9%B4%E5%BA%A6"
    "r1"  = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E4%BB%A4%E5%92%8C%E5%85%83%E5%B9%B4%E5%BA%A6"
    # --- Heisei (土地家屋調査士試験-平成{FW}年度) ---
    # 平成=E5B9B3E68890  年度=E5B9B4E5BAA6
    # full-width numbers: 17=EF BC 91 EF BC 97, 18=EF BC 91 EF BC 98, etc.
    "h30" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%93%EF%BC%90%E5%B9%B4%E5%BA%A6"
    "h29" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%99%E5%B9%B4%E5%BA%A6"
    "h28" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%98%E5%B9%B4%E5%BA%A6"
    "h27" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%97%E5%B9%B4%E5%BA%A6"
    "h26" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%96%E5%B9%B4%E5%BA%A6"
    "h25" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%95%E5%B9%B4%E5%BA%A6"
    "h24" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%94%E5%B9%B4%E5%BA%A6"
    "h23" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%93%E5%B9%B4%E5%BA%A6"
    "h22" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%92%E5%B9%B4%E5%BA%A6"
    "h21" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%91%E5%B9%B4%E5%BA%A6"
    "h20" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%92%EF%BC%90%E5%B9%B4%E5%BA%A6"
    "h19" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%91%EF%BC%99%E5%B9%B4%E5%BA%A6"
    "h18" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%91%EF%BC%98%E5%B9%B4%E5%BA%A6"
    "h17" = "%E5%9C%9F%E5%9C%B0%E5%AE%B6%E5%B1%8B%E8%AA%BF%E6%9F%BB%E5%A3%AB%E8%A9%A6%E9%A8%93-%E5%B9%B3%E6%88%90%EF%BC%91%EF%BC%97%E5%B9%B4%E5%BA%A6"
}

# Page prefix in URL: 過去問 followed by year key (e.g. h17, r7)
# e.g. 過去問h17-1  or  過去問r7-1
# Encoded: %E9%81%8E%E5%8E%BB%E5%95%8F
$kakomonEnc = "%E9%81%8E%E5%8E%BB%E5%95%8F"

# Determine which year keys to process
if ($All) {
    $yearKeys = @("h17","h18","h19","h20","h21","h22","h23","h24","h25","h26","h27","h28","h29","h30","r1","r2","r3","r4","r5","r6","r7")
} elseif ($Year -ne "") {
    $yearKeys = @($Year.ToLower())
} else {
    Write-Host "Usage:"
    Write-Host "  Single year : .\scraper.ps1 -Year r7"
    Write-Host "  Single year : .\scraper.ps1 -Year h17"
    Write-Host "  All years   : .\scraper.ps1 -All"
    exit 0
}

# Validate year keys
foreach ($yk in $yearKeys) {
    if (-not $yearDirMap.ContainsKey($yk)) {
        Write-Error "Unknown year key: '$yk'. Valid keys: h17..h30, r1..r7"
        exit 1
    }
}

# Output subject string in UTF-8
$subjectBytes = @(0xE5,0x9C,0x9F,0xE5,0x9C,0xB0,0xE5,0xAE,0xB6,0xE5,0xB1,0x8B,
                  0xE8,0xAA,0xBF,0xE6,0x9F,0xBB,0xE5,0xA3,0xAB)
$subjectStr   = [System.Text.Encoding]::UTF8.GetString($subjectBytes)   # 土地家屋調査士

# Create output directory
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# Category output strings (UTF-8 byte arrays to avoid encoding issues)
$catStr_Minpo    = [System.Text.Encoding]::UTF8.GetString([byte[]]@(  # 民法
    0xE6,0xB0,0x91,0xE6,0xB3,0x95))
$catStr_Fudou    = [System.Text.Encoding]::UTF8.GetString([byte[]]@(  # 不動産登記法
    0xE4,0xB8,0x8D,0xE5,0x8B,0x95,0xE7,0x94,0xA3,0xE7,0x99,0xBB,0xE8,0xA8,0x98,0xE6,0xB3,0x95))
$catStr_Chisatsu = [System.Text.Encoding]::UTF8.GetString([byte[]]@(  # 土地家屋調査士法
    0xE5,0x9C,0x9F,0xE5,0x9C,0xB0,0xE5,0xAE,0xB6,0xE5,0xB1,0x8B,
    0xE8,0xAA,0xBF,0xE6,0x9F,0xBB,0xE5,0xA3,0xAB,0xE6,0xB3,0x95))

# "誤っているもの" for inversion detection  (誤=E8AAA4 っ=E38183 て=E38186 い=E38184 る=E3828B も=E38282 の=E3818E)
$strMachigai = [System.Text.Encoding]::UTF8.GetString([byte[]]@(
    0xE8,0xAA,0xA4,0xE3,0x81,0xA3,0xE3,0x81,0xA6,0xE3,0x81,0x84,
    0xE3,0x82,0x8B,0xE3,0x82,0x82,0xE3,0x81,0xAE))

# --------------------------------------------------------------
# Helper functions
# --------------------------------------------------------------
function Strip-Html {
    param([string]$html)
    $t = $html -replace '<[^>]+>', ' '
    $t = $t -replace '&amp;',  '&'
    $t = $t -replace '&lt;',   '<'
    $t = $t -replace '&gt;',   '>'
    $t = $t -replace '&quot;', '"'
    $t = $t -replace '&nbsp;', ' '
    $t = $t -replace '\s{2,}', ' '
    return $t.Trim()
}

function Is-NoiseParagraph {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $true }
    $t = $s.Trim()
    $noiseWords = @(
        'お電話・メールお待ちしてます',
        '行政書士西尾真一事務所',
        'OFFICE NISHIO',
        'お問い合わせはこちらから',
        'お問い合わせフォーム',
        'プロフィール詳細はこちら',
        '年中無休',
        'LINE@',
        '〒',
        '📞',
        '✉',
        'Q&A',
        '消防署からの指摘',
        'ホッカイドウ　サッポロシ',
        '北海道札幌市東区東苗穂',
        '行政書士・土地家屋調査士・マンション管理士'
    )
    foreach ($w in $noiseWords) {
        if ($t.Contains($w)) { return $true }
    }
    if ($t -match 'ホッカイドウ.*サッポロシ') { return $true }
    if ($t -match '北海道札幌市.*東苗穂') { return $true }
    if ($t -match '東苗穂\d+条\d+丁目') { return $true }
    if ($t -match '行政書士.*土地家屋調査士.*マンション管理士') { return $true }
    return $false
}

# Full-width digit to int (e.g. [char]0xFF11 -> 1)
function FwToInt {
    param([string]$c)
    return [int][char]$c - 0xFF10
}

function To-FullWidthDigits {
    param([string]$s)
    $out = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -ge '0' -and $ch -le '9') {
            [void]$out.Append([char](0xFF10 + ([int][char]$ch - [int][char]'0')))
        } else {
            [void]$out.Append($ch)
        }
    }
    return $out.ToString()
}

function To-FullWidthAlphabets {
    param([string]$s)
    $out = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -ge 'a' -and $ch -le 'z') {
            [void]$out.Append([char](0xFF41 + ([int][char]$ch - [int][char]'a')))
        } elseif ($ch -ge 'A' -and $ch -le 'Z') {
            [void]$out.Append([char](0xFF21 + ([int][char]$ch - [int][char]'A')))
        } else {
            [void]$out.Append($ch)
        }
    }
    return $out.ToString()
}

function Get-QuestionUrlCandidates {
    param(
        [string]$baseUrl,
        [string]$yearKey,
        [int]$num,
        [string]$p1,
        [string]$p2,
        [string]$kakomonEnc
    )

    $nAscii = [string]$num
    $nFw    = To-FullWidthDigits $nAscii
    $ykLower = $yearKey.ToLower()
    
    # Generate year key variants: ASCII, full-width alphabets, full-width digits, combinations
    $ykAscii = $ykLower                          # h17, r3
    $ykFwAlpha = To-FullWidthAlphabets $ykLower # ｈ17, ｒ3
    $ykFwDigits = To-FullWidthDigits $ykLower   # h１７, r３
    $ykFwBoth = To-FullWidthAlphabets (To-FullWidthDigits $ykLower)  # ｈ１７, ｒ３

    $prefixes = @(
        $baseUrl,
        "https://www.nishio-shinichi-office.com/$p1/$p2/$kakomonEnc${ykAscii}-",
        "https://www.nishio-shinichi-office.com/$p1/$p2/$kakomonEnc${ykFwAlpha}-",
        "https://www.nishio-shinichi-office.com/$p1/$p2/$kakomonEnc${ykFwDigits}-",
        "https://www.nishio-shinichi-office.com/$p1/$p2/$kakomonEnc${ykFwBoth}-"
    ) | Select-Object -Unique

    # Generate as 年度キー × 問題番号 (4 combinations per prefix)
    $candidates = @()
    foreach ($prefix in $prefixes) {
        $candidates += "${prefix}${nAscii}/"     # h17-1/
        $candidates += "${prefix}${nFw}/"        # h17-１/
    }
    foreach ($yk in @($ykFwAlpha, $ykFwDigits, $ykFwBoth)) {
        $prefix = "https://www.nishio-shinichi-office.com/$p1/$p2/$kakomonEnc${yk}-"
        $candidates += "${prefix}${nAscii}/"
        $candidates += "${prefix}${nFw}/"
    }
    
    return $candidates | Select-Object -Unique
}

# Category by question number (fixed structure for Chisatsu exam)
function Get-Category {
    param([int]$n)
    if ($n -le 3)  { return $catStr_Minpo    }   # Q1-3:  民法
    if ($n -le 19) { return $catStr_Fudou    }   # Q4-19: 不動産登記法
                    return $catStr_Chisatsu      # Q20:   土地家屋調査士法
}

# --------------------------------------------------------------
# Scrape one year: returns array of question objects
# --------------------------------------------------------------
function Scrape-Year {
    param([string]$yk, [int]$startQ, [int]$endQ)

    $p2      = $yearDirMap[$yk]
    $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36' }

    # --- Auto-discover base URL from year index page ---
    # Some years use full-width ｈ/ｒ in the slug (e.g. 過去問ｈ18-1/) instead of ASCII h/r.
    # Fetch the index page and extract the actual href for 問題１.
    $baseUrl = "https://www.nishio-shinichi-office.com/$p1/$p2/$kakomonEnc${yk}-"  # fallback
    $yearIndexUrl = "https://www.nishio-shinichi-office.com/$p1/$p2/"
    try {
        $idxResp = Invoke-WebRequest -Uri $yearIndexUrl -UseBasicParsing -TimeoutSec 30 -Headers $headers
        $idxHtml = [System.Text.Encoding]::UTF8.GetString($idxResp.RawContentStream.ToArray())
        # href contains literal Japanese characters: data-action="button" href="/...過去問ｈ18-1/"
        $mIdx = [System.Text.RegularExpressions.Regex]::Match($idxHtml, 'data-action="button" href="(/[^"]*-1/)"')
        if ($mIdx.Success) {
            $q1href = $mIdx.Groups[1].Value
            # Strip trailing "1/" to get base (e.g. /.../%E9%81%8E%E5%8E%BB%E5%95%8F%EF%BD%8818-)
            $baseUrl = "https://www.nishio-shinichi-office.com" + $q1href.Substring(0, $q1href.Length - 2)
            Write-Host "  [auto] baseUrl confirmed: $baseUrl" -ForegroundColor Cyan
        } else {
            Write-Host "  [warn] 問題１リンクが見つかりません。デフォルトURLを使用します" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [warn] indexページ取得失敗。デフォルトURLを使用します: $_" -ForegroundColor Yellow
    }

    # ID prefix: uppercase (H17 / R7)
    $idPrefix = $yk.ToUpper()

    $Regex = [System.Text.RegularExpressions.Regex]
    $RO    = [System.Text.RegularExpressions.RegexOptions]

    $yearQuestions = @()

    for ($num = $startQ; $num -le $endQ; $num++) {
        $urlCandidates = Get-QuestionUrlCandidates -baseUrl $baseUrl -yearKey $yk -num $num -p1 $p1 -p2 $p2 -kakomonEnc $kakomonEnc
        Write-Host "[$yk] Fetching: $($urlCandidates[0])"

    $resp = $null
    $html = $null
    $usedUrl = $null
    $maxRetry = 4
    for ($retry = 1; $retry -le $maxRetry; $retry++) {
        foreach ($candidateUrl in $urlCandidates) {
            try {
                $resp = Invoke-WebRequest -Uri $candidateUrl -UseBasicParsing -TimeoutSec 60 -Headers $headers
                $html = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
                $usedUrl = $candidateUrl
                break
            } catch {
                # try next candidate
            }
        }
        if ($null -ne $html) { break }
        if ($retry -lt $maxRetry) {
            $waitSec = $retry * 10
            Write-Host "  RETRY [Q${num}] ($retry/${maxRetry}): ${waitSec}秒後に再試行..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitSec
        } else {
            Write-Host "  SKIP [Q${num}]: リトライ上限(${maxRetry}回)に達しました" -ForegroundColor Red
        }
    }
    if ($null -eq $html) { continue }
    if ($usedUrl -and $usedUrl -ne $urlCandidates[0]) {
        Write-Host "  [norm] resolved URL: $usedUrl" -ForegroundColor DarkCyan
    }

    # 1. Parse all paragraphs (used for limbs and choices)
    $paraMatches = $Regex::Matches($html, '<p[^>]*>(.+?)</p>', $RO::Singleline)

    # Full paragraph text joined (used for inversion & bracket-format detection)
    $fullText = ($paraMatches | ForEach-Object { Strip-Html $_.Groups[1].Value }) -join " "

    # Detect "誤っているもの" type → correct/incorrect meaning is inverted
    $isInverted = $fullText.Contains($strMachigai)

    # Detect dialogue format by keyword in problem body
    $isDialogueFormat = $fullText.Contains("対話")

    # 2. Limb texts - paragraphs starting with ア/イ/ウ/エ/オ; strip the leading letter
    $limbTexts = @()
    $limbContexts = @()
    $limbKeys = @()
    foreach ($pm in $paraMatches) {
        $stripped = Strip-Html $pm.Groups[1].Value
        if (Is-NoiseParagraph $stripped) { continue }
        if ($stripped -match $kataStart -and $stripped.Length -gt 10) {
            $marker = [string]$stripped[0]
            # Keep leading marker for dialogue questions; strip only in non-dialogue formats.
            if (-not $isDialogueFormat) {
                $stripped = $stripped -replace "^$kataClass[\s\t\u3000]+", ''
            }
            $limbTexts += $stripped.Trim()
            $limbContexts += ""
            $limbKeys += $marker
        } else {
            # Check for "prefix；ア　text" or "prefix：ア　text" pattern (e.g. 学生：ア　...) using direct char search
            $scPos = $stripped.IndexOf([char]0xFF1B)  # find ；
            if ($scPos -le 0 -and $stripped.IndexOf([char]0xFF1A) -gt 0) {
                $scPos = $stripped.IndexOf([char]0xFF1A)  # fallback: ： full-width colon
            }
            if ($scPos -le 0 -and $stripped.IndexOf([char]0x3B) -gt 0) {
                $scPos = $stripped.IndexOf([char]0x3B)  # fallback: half-width ;
            }
            if ($scPos -gt 0 -and $scPos -lt 10 -and ($scPos + 1) -lt $stripped.Length) {
                $mkIdx = $scPos + 1
                while ($mkIdx -lt $stripped.Length -and [char]::IsWhiteSpace($stripped[$mkIdx])) { $mkIdx++ }
                $nc = if ($mkIdx -lt $stripped.Length) { $stripped[$mkIdx] } else { [char]' ' }
                if ($kataMarkers -contains $nc `
                    -and $stripped.Length -gt 10) {
                    # Skip past ；/： + ア and any following whitespace
                    $startIdx = $mkIdx + 1
                    while ($startIdx -lt $stripped.Length -and [char]::IsWhiteSpace($stripped[$startIdx])) { $startIdx++ }
                    if ($startIdx -lt $stripped.Length - 5) {
                        $candidateLimb = $stripped.Substring($startIdx).Trim()
                        if ($isDialogueFormat) {
                            $candidateLimb = $stripped.Substring($mkIdx).Trim()
                        }
                        $limbTexts += $candidateLimb
                        $limbContexts += ""
                        $limbKeys += [string]$nc
                        $isDialogueFormat = $true
                    }
                }
            }
        }
    }

    # 3. Choice line - "１ アウ ２ アエ …"
    $choicesRaw = ""
    foreach ($pm in $paraMatches) {
        $stripped = Strip-Html $pm.Groups[1].Value
        $fc = if ($stripped.Length -gt 0) { [int][char]$stripped[0] } else { 0 }
        if ($fc -ge 0xFF11 -and $fc -le 0xFF15 -and $stripped.Length -gt 10) {
            $choicesRaw = $stripped
            break
        }
    }

    # 4. Correct answer from h2/h3 heading - find any heading containing a full-width digit
    $answerNum = 0
    $headingKataCombo = ""  # e.g. "アウエオ" from 正解４（ア、ウ、エ、オ）
    $headingCircledCombo = "" # e.g. "③④" from 正解２（③、④）
    $headMatches = $Regex::Matches($html, '<h[23][^>]*>(.+?)</h[23]>', $RO::Singleline)
    foreach ($hm in $headMatches) {
        $headText = Strip-Html $hm.Groups[1].Value
        if (-not $headText.Contains('正解')) { continue }
        # Prefer explicit "正解 <digit>" to avoid picking year digits (e.g. 平成２１年度)
        $mAns = $Regex::Match($headText, '正解\s*([1-5１２３４５])')
        if ($mAns.Success) {
            $ansRaw = $mAns.Groups[1].Value
            if ($ansRaw -match '^[1-5]$') {
                $answerNum = [int]$ansRaw
            } else {
                $answerNum = FwToInt $ansRaw
            }
        }

        # Extract parenthetical combo from heading
        $ob = [char]0xFF08; $cb = [char]0xFF09
        $parenPat = [string]$ob + "[^" + [string]$cb + "]+" + [string]$cb
        $pm_h = $Regex::Match($headText, $parenPat)
        if ($pm_h.Success) {
            $headingKataCombo = $Regex::Replace($pm_h.Value, "[^$kataMarkerClassText]", "")
            $headingCircledCombo = $Regex::Replace($pm_h.Value, "[^①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]", "")
        }
        if ($headingKataCombo -eq "") {
            # Some pages write: 正解 2 ア・ウ (without parentheses)
            $mKata = $Regex::Match($headText, "正解\s*[1-5１２３４５]\s*([$kataMarkerClassText、,\s\u3000・]{1,20})")
            if ($mKata.Success) {
                $headingKataCombo = $Regex::Replace($mKata.Groups[1].Value, "[^$kataMarkerClassText]", "")
            }
        }
        if ($headingCircledCombo -eq "") {
            # Some pages write "正解 2 ③、④" without parentheses
            $headingCircledCombo = $Regex::Replace($headText, "[^①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]", "")
        }

        if ($answerNum -gt 0 -or $headingKataCombo -ne "" -or $headingCircledCombo -ne "") { break }
    }

    # Fallback: extract from full page text when heading does not include answer metadata
    if ($answerNum -eq 0 -or ($headingKataCombo -eq "" -and $headingCircledCombo -eq "")) {
        $flatText = Strip-Html $html
        $mFlat = $Regex::Match($flatText, '正解[\s\u3000]*([1-5１２３４５])[\s\u3000]*([①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳、,\s\u3000]*)')
        if ($mFlat.Success) {
            if ($answerNum -eq 0) {
                $ansRaw2 = $mFlat.Groups[1].Value
                if ($ansRaw2 -match '^[1-5]$') { $answerNum = [int]$ansRaw2 }
                else { $answerNum = FwToInt $ansRaw2 }
            }
            if ($headingCircledCombo -eq "") {
                $headingCircledCombo = $Regex::Replace($mFlat.Groups[2].Value, "[^①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]", "")
            }
        }
        if ($headingKataCombo -eq "") {
            $mFlatK = $Regex::Match($flatText, "正解[\s\u3000]*([1-5１２３４５])[\s\u3000]*([$kataMarkerClassText、,\s\u3000・]{1,20})")
            if ($mFlatK.Success) {
                $headingKataCombo = $Regex::Replace($mFlatK.Groups[2].Value, "[^$kataMarkerClassText]", "")
            }
        }
    }

    # 2b. Fallback: digit-numbered limbs (１〜５) — single-answer questions
    #     e.g. "１　仮差押えの登記が..." rather than "ア　..."
    $isDigitFormat = $false
    if ($limbTexts.Count -eq 0) {
        foreach ($pm in $paraMatches) {
            $stripped2 = Strip-Html $pm.Groups[1].Value
            $fc2 = if ($stripped2.Length -gt 0) { [int][char]$stripped2[0] } else { 0 }
            # Full-width digits １-５ are 0xFF11-0xFF15
            if ($fc2 -ge 0xFF11 -and $fc2 -le 0xFF15 -and $stripped2.Length -gt 15) {
                # Skip if this looks like the choice combination line:
                # "１ アウ ２ アエ ..." — short katakana bursts after each digit
                $isChoiceLine = $stripped2 -match "$fwClass[\s　]$kataClass{2,3}"
                if (-not $isChoiceLine) {
                    # Keep leading number for dialogue questions; strip only in non-dialogue formats.
                    $digitMarker = ''
                    $dm = [System.Text.RegularExpressions.Regex]::Match($stripped2, '^[０-９]+')
                    if ($dm.Success) { $digitMarker = $dm.Value }
                    if (-not $isDialogueFormat) {
                        $stripped2 = $stripped2 -replace "^$fwClass[\s\t\u3000　]+", ''
                    }
                    $limbTexts += $stripped2.Trim()
                    $isDigitFormat = $true
                    $limbKeys += $digitMarker
                }
            }
        }
    }

    # 2d. Dialogue format: collect questionText from non-answer paragraphs
    #     (intro + speaker question lines become shared question context)
    if ($isDialogueFormat -and $limbTexts.Count -gt 0) {
        $qParts = @()
        foreach ($pm in $paraMatches) {
            $s = Strip-Html $pm.Groups[1].Value
            if (Is-NoiseParagraph $s) { continue }
            if ($s.Length -lt 10) { continue }
            # Skip choice line (starts with full-width digit)
            $fc0 = [int][char]$s[0]
            if ($fc0 -ge 0xFF11 -and $fc0 -le 0xFF15) { continue }
            # Skip speaker answer lines (have ；/： + optional spaces + katakana at position < 10)
            $isAnswer = $false
            foreach ($sep in @([char]0xFF1B, [char]0xFF1A, [char]0x3B)) {
                $p2 = $s.IndexOf($sep)
                if ($p2 -gt 0 -and $p2 -lt 10) {
                    $mk2 = $p2 + 1
                    while ($mk2 -lt $s.Length -and [char]::IsWhiteSpace($s[$mk2])) { $mk2++ }
                    $nc2 = if ($mk2 -lt $s.Length) { $s[$mk2] } else { [char]' ' }
                    if ($kataMarkers -contains $nc2) {
                        $isAnswer = $true; break
                    }
                }
            }
            if (-not $isAnswer) { $qParts += $s }
        }
        $questionTextRaw = ($qParts | Where-Object { $_.Length -gt 5 }) -join "`n"
    }

    # 2c. Fallback: bracket-embedded format 「（ア）...（イ）...」 within question text
    $isBracketFormat = $false
    $questionTextRaw = if ($isDialogueFormat) { $questionTextRaw } else { "" }
    if ($limbTexts.Count -eq 0) {
        $ob = [char]0xFF08
        $cb = [char]0xFF09
        # Use string concatenation to avoid PowerShell parsing $ob[$...] as array index
        $bracketPat = [string]$ob + "$kataClass" + [string]$cb
        if ($Regex::IsMatch($fullText, $bracketPat)) {
            $isBracketFormat = $true
            $questionTextRaw = $fullText
            $parts = $Regex::Split($fullText, $bracketPat)
            $bracketMatches = $Regex::Matches($fullText, $bracketPat)
            for ($pi = 1; $pi -lt $parts.Count; $pi++) {
                $seg = $parts[$pi]
                # Strip trailing choices line e.g. "１ アウ ２ アオ..."
                # Pattern built via concatenation to avoid string-expansion issues
                $cjPat = [string]$d[0] + '\s+' + "$kataClass{2,3}\s+" + [string]$d[1]
                $cjm   = $Regex::Match($seg, $cjPat)
                if ($cjm.Success -and $cjm.Index -gt 3) { $seg = $seg.Substring(0, $cjm.Index) }
                $seg = $seg.Trim()
                if ($seg.Length -gt 3) {
                    $limbTexts += $seg
                    if (($pi - 1) -lt $bracketMatches.Count) {
                        $bm = [string]$bracketMatches[$pi - 1].Value
                        $limbKeys += ($Regex::Replace($bm, "[^$kataMarkerClassText]", ""))
                    } else {
                        $limbKeys += ''
                    }
                }
            }
        }
    }

    # 2e. Standard katakana-direct / digit format: collect questionText from preamble paragraphs
    #     (paragraphs that appear before the first limb paragraph)
    if (-not $isDialogueFormat -and -not $isBracketFormat -and $limbTexts.Count -gt 0) {
        $qParts = @()
        foreach ($pm in $paraMatches) {
            $s = Strip-Html $pm.Groups[1].Value
            if (Is-NoiseParagraph $s) { continue }
            if ($s.Length -lt 5) { continue }
            # Stop at first katakana-direct limb
            if ($s -match $kataStart -and $s.Length -gt 10) { break }
            # Stop at first digit-format limb (full-width digit + longer text)
            $fc0 = if ($s.Length -gt 0) { [int][char]$s[0] } else { 0 }
            if ($fc0 -ge 0xFF11 -and $fc0 -le 0xFF15 -and $s.Length -gt 15) { break }
            # Skip colon/semicolon-prefix limb lines (dialogue format guard)
            $hasKataSep = $false
            foreach ($sep in @([char]0xFF1B, [char]0xFF1A, [char]0x3B)) {
                $p2 = $s.IndexOf($sep)
                if ($p2 -gt 0 -and $p2 -lt 10) {
                    $nc2 = if (($p2 + 1) -lt $s.Length) { $s[$p2 + 1] } else { [char]' ' }
                    if ($kataMarkers -contains $nc2) {
                        $hasKataSep = $true; break
                    }
                }
            }
            if ($hasKataSep) { continue }
            $qParts += $s
        }
        if ($qParts.Count -gt 0) {
            $questionTextRaw = ($qParts | Where-Object { $_.Length -gt 5 }) -join "`n"
        }
    }

    # 2f. Fallback: some pages place the lead question text outside usable <p> blocks.
    #     Recover it from the flattened page HTML by taking the text before the first limb.
    if ([string]::IsNullOrWhiteSpace($questionTextRaw) -and $limbTexts.Count -gt 0) {
        $flatPageText = (Strip-Html $html) -replace '\s+', ' '
        $flatPageText = $flatPageText.Trim()

        $firstLimbText = [string]$limbTexts[0]
        $probe = if ($firstLimbText.Length -gt 18) { $firstLimbText.Substring(0, 18) } else { $firstLimbText }
        $firstLimbPos = if ($probe -ne '') { $flatPageText.IndexOf($probe) } else { -1 }

        if ($firstLimbPos -gt 0) {
            $prefix = $flatPageText.Substring(0, $firstLimbPos).Trim()

            # If the page title is repeated, keep the text after the last "問題NN" marker.
            $numFw = To-FullWidthDigits([string]$num)
            $markerPos = -1
            foreach ($marker in @("問題$numFw", "問題$num")) {
                $pos = $prefix.LastIndexOf($marker)
                if ($pos -ge 0) { $markerPos = [Math]::Max($markerPos, $pos + $marker.Length) }
            }
            if ($markerPos -gt 0 -and $markerPos -lt $prefix.Length) {
                $prefix = $prefix.Substring($markerPos).Trim()
            }

            # Trim obvious trailing site noise if it slipped in.
            $prefix = $Regex::Replace($prefix, '\s*正解\s*[1-5１２３４５].*$', '', $RO::Singleline)
            $prefix = $Regex::Replace($prefix, '\s*お電話・メールお待ちしてます.*$', '', $RO::Singleline)
            $prefix = $Regex::Replace($prefix, "[。．]\\s*$kataClass\\s*$", '。')
            $prefix = $Regex::Replace($prefix, "\\s+$kataClass$", '')
            $prefix = ($prefix -replace '\s+', ' ').Trim()

            if ($prefix.Length -gt 5) {
                $questionTextRaw = $prefix
            }
        }
    }

    if ($limbTexts.Count -eq 0) {
        Write-Warning "  SKIP [Q${num}]: no limbs found"
        continue
    }

    $category = Get-Category $num

    # 6. Build limb objects
    $limbs = @()

    # 5b. Inline OX format is disabled to keep non-dialogue questions as normal OX limbs.
    $inlineWrongKeys = @()
    if ($headingCircledCombo -ne "") {
        foreach ($ch in $headingCircledCombo.ToCharArray()) { $inlineWrongKeys += [string]$ch }
    }
    $inlineTermMatches = $Regex::Matches($questionTextRaw, '（[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳][^）]*）')
    $isInlineOxFormat = $false

    if ($isInlineOxFormat) {
        $inlineText = $questionTextRaw
        # Append 〇× after each numbered term while preserving the original sentence as much as possible
        $inlineText = $Regex::Replace($inlineText, '（([①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳][^）]*[^）\s])）', '（$1）〇×')

        $limbs += [PSCustomObject]@{
            id           = "${idPrefix}-${num}-l0"
            text         = $inlineText
            context      = ""
            correct      = $true
            inlineOxWrong = @($inlineWrongKeys)
            explanation  = ""
        }

        # Keep prompt line only in questionText to avoid duplicated long text rendering
        $firstLine = ($questionTextRaw -split "`n")[0]
        $questionTextRaw = $firstLine
    }

    if (-not $isInlineOxFormat -and $isDigitFormat) {
        # Single-answer format: correct limb index = answerNum - 1
        # If "誤っているもの" type, the answer points to the WRONG limb
        $correctCombo = if ($answerNum -ge 1 -and $answerNum -le $d.Count) { "$answerNum" } else { "" }
        for ($limbIdx = 0; $limbIdx -lt $limbTexts.Count; $limbIdx++) {
            $isCorrect = if ($isInverted) { (($limbIdx + 1) -ne $answerNum) } else { (($limbIdx + 1) -eq $answerNum) }
            $limbs += [PSCustomObject]@{
                id          = "${idPrefix}-${num}-l${limbIdx}"
                text        = $limbTexts[$limbIdx]
                context     = ""
                correct     = [bool]$isCorrect
                explanation = ""
            }
        }
    } elseif (-not $isInlineOxFormat) {
        # Combination format (katakana or bracket): parse choice line "１ アウ ２ アエ …"
        $choicePattern = "$fwClass[\s\t ]+($kataClass{2,3})"
        $choiceMatches = $Regex::Matches($choicesRaw, $choicePattern)
        $choiceMap = @{}
        $cidx = 1
        foreach ($cm in $choiceMatches) {
            $choiceMap[$cidx] = $cm.Groups[1].Value
            $cidx++
        }

        # Fallback: when choice line paragraph wasn't isolated, parse from full joined text.
        # Example target: "１ アエ ２ アオ ３ イウ ４ イエ ５ ウオ"
        if ($choiceMap.Count -eq 0) {
            $flatChoice = ($fullText -replace '\s+', ' ')
            $comboLineMatch = $Regex::Match(
                $flatChoice,
                "[１２３４５]\s*$kataClass{2,3}(?:\s*[１２３４５]\s*$kataClass{2,3}){2,}"
            )
            if ($comboLineMatch.Success) {
                $fallbackMatches = $Regex::Matches($comboLineMatch.Value, "$fwClass\s*($kataClass{2,3})")
                $fi = 1
                foreach ($fm in $fallbackMatches) {
                    $choiceMap[$fi] = $fm.Groups[1].Value
                    $fi++
                }
            }
        }

        # Combination format: correctCombo comes from choice line or heading parenthetical.
        $correctCombo = if ($choiceMap.ContainsKey($answerNum)) { $choiceMap[$answerNum] } `
                        elseif ($headingKataCombo -ne "") { $headingKataCombo } `
                        else { "" }

        for ($limbIdx = 0; $limbIdx -lt $limbTexts.Count; $limbIdx++) {
            $letter = if ($limbIdx -lt $limbKeys.Count -and -not [string]::IsNullOrWhiteSpace([string]$limbKeys[$limbIdx])) {
                [string]$limbKeys[$limbIdx]
            } elseif ($limbIdx -lt $kataMarkers.Count) {
                [string]$kataMarkers[$limbIdx]
            } else {
                [string]($limbIdx + 1)
            }
            # If "誤っているもの" type, combo contains WRONG limbs【1=invert】
            $isCorrect = if ($isInverted) { -not ($correctCombo.Contains($letter)) } else { $correctCombo.Contains($letter) }
            $limbs += [PSCustomObject]@{
                id          = "${idPrefix}-${num}-l${limbIdx}"
                text        = $limbTexts[$limbIdx]
                context     = ""
                correct     = [bool]$isCorrect
                explanation = ""
            }
        }

        # Dialogue questions: rebuild full conversation in document order.
        # Answer lines become （key）〇× format; professor/other lines stay verbatim.
        # app.js renderInlineOxText() then embeds ○× buttons at those exact positions.
        if ($isDialogueFormat -and $limbs.Count -ge 1) {
            $inlineWrongKeys = @()

            # Build key → correct mapping from already-extracted limbs
            $correctByKey = @{}
            for ($i = 0; $i -lt $limbs.Count; $i++) {
                $key = if ($i -lt $limbKeys.Count -and -not [string]::IsNullOrWhiteSpace([string]$limbKeys[$i])) {
                    [string]$limbKeys[$i]
                } elseif ($i -lt $kataMarkers.Count) {
                    [string]$kataMarkers[$i]
                } else { [string]($i + 1) }
                $correctByKey[$key] = [bool]$limbs[$i].correct
                if (-not [bool]$limbs[$i].correct) { $inlineWrongKeys += $key }
            }

            # Walk paragraphs in document order to preserve conversation flow
            $introLines  = @()
            $convLines   = @()
            $firstAnsFound = $false

            foreach ($pmD in $paraMatches) {
                $sD = Strip-Html $pmD.Groups[1].Value
                if (Is-NoiseParagraph $sD) { continue }
                if ($sD.Length -lt 5) { continue }
                # Skip choice combination line (full-width digit + short katakana bursts)
                $fcD = if ($sD.Length -gt 0) { [int][char]$sD[0] } else { 0 }
                if ($fcD -ge 0xFF11 -and $fcD -le 0xFF15 -and ($sD -match "$kataClass{2,3}")) { continue }

                # Detect "speaker：ア　text" answer line
                $isSepAns = $false
                $speakerPfx = ''
                $aKey = ''
                $aBody = ''
                foreach ($sepD in @([char]0xFF1B, [char]0xFF1A, [char]0x3B)) {
                    $p2i = $sD.IndexOf($sepD)
                    if ($p2i -gt 0 -and $p2i -lt 10) {
                        $mk2i = $p2i + 1
                        while ($mk2i -lt $sD.Length -and [char]::IsWhiteSpace($sD[$mk2i])) { $mk2i++ }
                        $nc2i = if ($mk2i -lt $sD.Length) { $sD[$mk2i] } else { [char]' ' }
                        if ($kataMarkers -contains $nc2i) {
                            $isSepAns   = $true
                            $speakerPfx = $sD.Substring(0, $p2i + 1)  # e.g. "学生："
                            $aKey       = [string]$nc2i
                            $startI     = $mk2i + 1
                            while ($startI -lt $sD.Length -and [char]::IsWhiteSpace($sD[$startI])) { $startI++ }
                            $aBody = if ($startI -lt $sD.Length) { $sD.Substring($startI).Trim() } else { '' }
                            break
                        }
                    }
                }

                # Detect katakana-start answer line (ア　text...) with no speaker prefix
                $isKataAns = $false
                if (-not $isSepAns -and ($sD -match $kataStart) -and $sD.Length -gt 10) {
                    $isKataAns = $true
                    $aKey  = [string]$sD[0]
                    $aBody = ($sD -replace "^$kataClass[\s\t\u3000　]+", '').Trim()
                }

                if ($isSepAns -or $isKataAns) {
                    $firstAnsFound = $true
                    if ($isSepAns) {
                        $convLines += "${speakerPfx}（${aKey}）〇× ${aBody}"
                    } else {
                        $convLines += "（${aKey}）〇× ${aBody}"
                    }
                } else {
                    if ($firstAnsFound) {
                        $convLines += $sD   # professor / other line mid-dialogue
                    } else {
                        # Before first answer: speaker lines (e.g. 教授：...) belong to dialogue flow.
                        if ($sD -match '^.{1,15}[；：;]\s*') {
                            $convLines += $sD
                        } else {
                            $introLines += $sD  # opening problem statement before dialogue starts
                        }
                    }
                }
            }

            # Intro paragraphs = questionText; dialogue body = single limb text with inline OX markers
            if ($introLines.Count -gt 0) {
                $questionTextRaw = ($introLines | Where-Object { $_.Length -gt 5 }) -join "`n"
            }

            $limbs = @(
                [PSCustomObject]@{
                    id            = "${idPrefix}-${num}-l0"
                    text          = ($convLines -join "`n")
                    context       = ""
                    correct       = $true
                    inlineOxWrong = @($inlineWrongKeys)
                    explanation   = ""
                }
            )
            $isInlineOxFormat = $true
        }

    }

    $question = [PSCustomObject]@{
        id           = "${idPrefix}-${num}"
        subject      = $subjectStr
        category     = $category
        source       = "${idPrefix}-$num"
        questionText = $questionTextRaw
        limbs        = $limbs
        correctCombo = $correctCombo
    }
    $yearQuestions += $question

    $fmt = if ($isBracketFormat) { "bracket" } elseif ($isDigitFormat) { "digit" } else { "combo" }
    $inv = if ($isInverted) { " [inverted]" } else { "" }
    Write-Host "  -> Q${num}: answer=${answerNum} combo=${correctCombo} limbs=$($limbs.Count) [${fmt}]${inv}"
    Start-Sleep -Milliseconds 2000
    }

    return ,$yearQuestions
}

# --------------------------------------------------------------
# Main: scrape each year and write JSON
# --------------------------------------------------------------
$allCombined = @()
$existingAll = @()

if (Test-Path (Join-Path $OutDir 'all_questions.json')) {
    try {
        $existingAll = Get-Content (Join-Path $OutDir 'all_questions.json') -Raw | ConvertFrom-Json
        if ($existingAll -isnot [System.Collections.IEnumerable]) { $existingAll = @($existingAll) }
    } catch {
        $existingAll = @()
    }
}

foreach ($yk in $yearKeys) {
    Write-Host ""
    Write-Host "====== Year: $yk ======"
    $qs = Scrape-Year -yk $yk -startQ $Start -endQ $End

    # Write per-year file
    $outFile = Join-Path $OutDir "${yk}_questions.json"
    $json = ConvertTo-Json -InputObject @($qs) -Depth 10
    [System.IO.File]::WriteAllText(
        (Join-Path (Resolve-Path $OutDir).Path "${yk}_questions.json"),
        $json,
        [System.Text.Encoding]::UTF8
    )
    Write-Host "  Saved: $outFile  ($($qs.Count) questions)"

    $allCombined += $qs
}

# Always refresh the aggregate file so the browser app can pick up the latest questions.
if ($allCombined.Count -gt 0) {
    $mergedFile = Join-Path $OutDir "all_questions.json"
    if ($All) {
        $mergedQuestions = @($allCombined)
    } else {
        $currentYearSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@())
        foreach ($q in $allCombined) {
            if ($q.source) { [void]$currentYearSet.Add([string]$q.source) }
        }
        $mergedQuestions = @($existingAll | Where-Object { -not $currentYearSet.Contains([string]$_.source) }) + @($allCombined)
    }
    $json = ConvertTo-Json -InputObject @($mergedQuestions) -Depth 10
    [System.IO.File]::WriteAllText(
        (Join-Path (Resolve-Path $OutDir).Path "all_questions.json"),
        $json,
        [System.Text.Encoding]::UTF8
    )
    Write-Host ""
    Write-Host "Merged file: $mergedFile  ($($mergedQuestions.Count) total questions)"
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Note: 'explanation' fields are empty (free site has no explanations)"
Write-Host "Import via: App > Problem Management > JSON Import"
