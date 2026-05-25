# Gyosei Quiz App

Administrative scrivener one-question-one-answer web app.

## Scope
- Standalone repository for the new app
- Firebase will be configured from scratch
- Data source can be generated separately by the scraper repository

## Local Preview
Run with a local web server (do not open via file://).

PowerShell example:

```powershell
cd F:\開発中アプリ\行政書士
py -m http.server 5500
```

Then open:

http://localhost:5500/index.html

## Next Steps
1. Create a new Firebase project
2. Add web app config in `firebase-config.js`
3. Initialize Hosting and Firestore in this repository
4. Import question data to Firestore or load JSON from `data/`
