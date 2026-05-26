# Gyosei Quiz App

行政書士試験向けの一問一答Webアプリです。

## 対象範囲
- この新規アプリ専用の独立リポジトリ
- Firebase はこのリポジトリで新規に設定
- データソースはスクレイパー用リポジトリで別途生成可能

## ローカルでの確認方法
ローカルWebサーバーで起動してください（file:// で直接開かないでください）。

PowerShell の例:

```powershell
cd F:\開発中アプリ\行政書士
py -m http.server 5500
```

その後、以下を開きます:

http://localhost:5500/index.html

## 次のステップ
1. 新しい Firebase プロジェクトを作成する
2. firebase-config.js に Web アプリ設定を追加する
3. このリポジトリで Hosting と Firestore を初期化する
4. 問題データを Firestore に取り込む、または data/ の JSON を読み込む


https://d1424-da.github.io/gyosei-quiz-app/