# 行政書士過去問スクレーパー

`gyosyo_scraper.ps1` は、以下のページを起点に行政書士過去問を抽出し、`app.js` で読み込み可能なJSON形式で出力するスクリプトです。

- インデックスページ: https://gyosyo.info/%E8%A1%8C%E6%94%BF%E6%9B%B8%E5%A3%AB%E3%81%AE%E9%81%8E%E5%8E%BB%E5%95%8F%E9%9B%86%EF%BC%88%E5%95%8F%E9%A1%8C%E3%81%A8%E8%A7%A3%E8%AA%AC%EF%BC%89/

## 使い方

```powershell
# 動作確認（令和7年・問1〜問5のみ）
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -Year r7 -StartQuestion 1 -EndQuestion 5

# 特定の年度のみ取得
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -Year h24 -StartQuestion 1 -EndQuestion 60

# インデックスページに掲載されている全年度を取得
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -All -StartQuestion 1 -EndQuestion 60

# キャッシュを使用してオフラインで実行（HTMLキャッシュ済みの場合）
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -Offline -All
```

## 出力ファイル

- `output/gyosyo_<年度>_questions.json` … 年度別の問題データ
- `output/gyosyo_all_questions.json` … 全年度をまとめたデータ
- `output/all_questions.json` … 上記と同内容の互換ファイル

各レコードは以下の構造を持ちます：

| フィールド | 内容 |
|---|---|
| `id` | 問題ID（例: `R5-48`） |
| `subject` | 科目（行政書士） |
| `category` | カテゴリ（例: 基礎知識） |
| `source` | 出典（例: 令和5年・2023｜問48｜基礎知識・政治） |
| `questionText` | 問題文 |
| `limbs[]` | 各肢のデータ（`id`, `text`, `correct`, `explanation`） |
| `questionUrl` | 元ページのURL |
| `correctOption` | 正答番号（1〜5） |
| `answerType` | 問題種別（`choice` / `combo_ox` / `text`） |

## 問題種別について

| 種別 | 説明 |
|---|---|
| `choice` | 5択問題。各肢は `correct: true/false` で正誤を示す。「妥当でないもの」形式は自動反転。 |
| `combo_ox` | 組合せ問題（ア〜オの正誤組合せ）。各肢に `correct` フラグ付き。 |
| `text` | 記述式問題。`correctText` および `acceptedAnswers` を持つ。 |

## キャッシュについて

- 取得したHTMLは `cache/html/` 以下にSHA-256ハッシュ名で保存されます。
- `-Offline` オプションを指定するとネットワークアクセスを行わず、キャッシュのみを使用します。
- キャッシュがない状態で `-Offline` を使用するとエラーになります。

## 注意事項

- ソースページのHTML構造が非標準の場合、一部の問題がスキップされることがあります。スキップされた問題は警告として表示されます。
- 途中で中断した場合は再実行してください。出力ファイルは年度単位で上書きされます。
- `build_limb_questions.ps1` を実行すると、各肢を独立した○×問題に変換した `output/limb_questions.json` が生成されます。
