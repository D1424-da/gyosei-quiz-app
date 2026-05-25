# Gyosyo Scraper

`gyosyo_scraper.ps1` は、以下ページを起点に行政書士過去問を抽出して、`app.js` で取り込み可能なJSONを出力します。

- Index: https://gyosyo.info/%E8%A1%8C%E6%94%BF%E6%9B%B8%E5%A3%AB%E3%81%AE%E9%81%8E%E5%8E%BB%E5%95%8F%E9%9B%86%EF%BC%88%E5%95%8F%E9%A1%8C%E3%81%A8%E8%A7%A3%E8%AA%AC%EF%BC%89/

## Usage

```powershell
# Test (R7, Q1-Q5)
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -Year r7 -StartQuestion 1 -EndQuestion 5

# Single year
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -Year h24 -StartQuestion 1 -EndQuestion 60

# All years found on index page
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -All -StartQuestion 1 -EndQuestion 60
```

## Output

- `output/gyosyo_<year>_questions.json`
- `output/gyosyo_all_questions.json`

Each record uses this structure:

- `id`
- `subject`
- `category`
- `source`
- `questionText`
- `limbs[]`
- `questionUrl`
- `correctOption`

## Notes

- Multi-choice questions are converted into `limbs` where only one option has `correct: true`.
- Descriptive questions are imported as free-text items with `correctText` and `acceptedAnswers`.
- Some questions may still be skipped when the source page has a non-standard answer block or malformed HTML.
- If a run is interrupted, execute again; files are overwritten per year.
