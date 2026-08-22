# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

行政書士試験（Japanese administrative scrivener exam）向けの一問一答Webアプリ。静的なフロントエンド（バニラJS、ビルドステップなし）と、過去問データを収集・変換・検証するPython/PowerShellのデータパイプラインの2部構成。

## Commands

There is no `package.json`, build step, linter, or test suite in this repo — it's plain HTML/CSS/JS served statically.

**Run the app locally** (must be served over HTTP, not opened via `file://`, or Firebase Auth and data loading will fail):
```bash
python -m http.server 5500
# then open http://localhost:5500/index.html
```

**After editing `app.js`, `auth-module.js`, or `firebase-config.js`**, bump the `?v=...` query-string suffix on the corresponding `<script>` tag in `index.html` — browsers/GitHub Pages otherwise serve a stale cached copy.

**Firebase deploy** (hosting + Firestore rules/indexes, project id in `.firebaserc`):
```bash
firebase deploy
```

### Data pipeline (Python)

No `requirements.txt`; install ad hoc (`requests`, and `google-genai` only for the Gemini-based scripts). Scripts are run individually, each with its own `--help`-style docstring at the top of the file:

```bash
python normalize_categories.py [--dry-run]                    # collapse category labels 75→17, adds topCategory
python convert_to_oxquiz.py [--input output/gyosyo_all_questions.json]   # multi-choice → O/X, no API needed
python generate_oxquiz.py --limit 50                            # same, but via Gemini API (needs GEMINI_API_KEY)
python audit_cache_html.py [--ids H23-20 H30-32] [--category 民法] [--apply-safe]  # cross-check JSON vs cached HTML
python verify_answers.py --cache-only --dry-run                 # verify/fix combo_ox correctness (HTML cache → Gemini cache → live API)
```

### Data pipeline (PowerShell, Windows only)

```powershell
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -Offline -All        # rebuild all years from cached HTML
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -Offline -Year r7    # rebuild one year
powershell -ExecutionPolicy Bypass -File .\gyosyo_scraper.ps1 -All -StartQuestion 1 -EndQuestion 60   # live scrape, all years
```
`-Offline` uses only `cache/html/` (SHA-256-named cached pages) and never hits the network; without cached HTML it errors instead of fetching.

## Architecture

### Data pipeline → frontend flow

1. `gyosyo_scraper.ps1` scrapes gyosyo.info, caches raw HTML under `cache/html/<sha256>.html`, and writes `output/gyosyo_<year>_questions.json` + a merged `output/gyosyo_all_questions.json`. Each question has `id` (e.g. `R5-48`), `subject`, `category`, `source`, `questionText`, `limbs[]` (`id`, `text`, `correct`, `explanation`), and `answerType` (`choice` / `combo_ox` / `text`).
2. `convert_to_oxquiz.py` converts multi-choice/combo questions into standalone O/X limbs, skipping text-answer, fill-in-blank, and questions whose limbs can't be judged independently → `output/oxquiz_questions.json`. (`generate_oxquiz.py` is an alternative path that does this via the Gemini API instead of rules.)
3. `normalize_categories.py` collapses ~75 raw category labels down to 17 canonical ones (and adds `topCategory`: 法令科目/一般知識等), operating in place on `output/oxquiz_questions.json`.
4. `audit_cache_html.py` / `verify_answers.py` re-parse the cached HTML as ground truth and flag/fix mismatches (wrong `correct` flags, missing limbs, unresolved combo answers) against the generated JSON — see the docstrings at the top of each file for the exact heuristics (`combo_ox` answers are derived by reverse-engineering the "正しい組合せ" choice list rather than trusting explanation text, because explanation wording isn't reliably binary).
5. `quiz_utils.py` holds the shared path constants (`OUTPUT_DIR`, `CACHE_HTML_DIR`, etc.) and JSON/text-normalization helpers used across the above scripts — extend it rather than duplicating helpers in a new script.
6. At runtime, `app.js`'s `syncBundledQuestions()` fetches `output/oxquiz_questions.json` (falling back to `output/gyosyo_all_questions.json`, then `output/all_questions.json`) on page load, unless a signed-in user already has newer data in Firestore (`question_bank_years` collection) or `localDirty` local edits.

### Frontend (`app.js`, `auth-module.js`, `firebase-config.js`, `index.html`)

- **No framework/bundler.** Everything is plain DOM manipulation from a single ~4000-line `app.js`. Script load order matters: Firebase compat SDKs → `firebase-config.js` (sets `window.APP_CONFIG.adminEmails`, initializes `firebase.initializeApp`) → `auth-module.js` (login/register/reset UI + `firebase.auth()` wiring) → `app.js`.
- **localStorage** is namespaced (`gyosei::<key>`) via `nsKey()`/`storageGetItem`/`storageSetItem`/`storageGetJSON`/`storageSetJSON`; most per-user keys (`limb_records`, `limb_study_time`, `limb_study_calendar`, `limb_study_session`, etc.) are suffixed with the Firebase Auth uid.
- **Cloud sync (Firestore) is local-first**, not a simple read/write:
  - `records/{uid}` holds each limb's `{correct, wrong, wrongDateKeys, lastWrong, review, mastery, masteryUpdatedAtMs}`, plus study-calendar and study-session-snapshot fields bolted onto the same document.
  - Answers are queued as deltas (`pendingRecordDeltas`, `addPendingRecordDelta`) and flushed with `firebase.firestore.FieldValue.increment()` via `flushRecordDeltasToCloudIfNeeded()`, so concurrent devices don't clobber each other's counters. Full snapshots go through `pushRecordsToCloud()`/`recordsPendingSync`.
  - Realtime listeners (`startCloudRealtimeSubscriptions`) and pull functions (`pullRecordsFromCloudIfNeeded`) merge remote data into local state with `mergeRecordsNoLoss()` (counters only ever increase; the newer `review`/`mastery` timestamp wins) rather than overwriting — this exists specifically to avoid losing not-yet-synced local answers when two conditions race.
  - `lastWrong` is a **tri-state** field (`true` / `false` / `null`), not a plain boolean — `null` means "no explicit signal, fall back to `wrong > 0`" for backward compatibility with older data. Always read it through `isLastWrong(stat)`, never compare `stat.lastWrong` directly. `repairLastWrongData()` is a one-time migration (tracked via `_repairedLimbIds`/`_repairDone`) that fixes historical data where this field was incorrectly written as `false`.
- **Question/limb data model**: `questions[]` → each has `subject`/`category`/`source`/`questionText`/`limbs[]`. A limb can be a plain O/X limb, a multi-choice limb (`options[]` + `correctText`), a free-text limb (`acceptedAnswers[]`), or an inline O/X limb (「（①語句）〇×」 markers parsed out of `text` by `parseInlineOxItems`/`getInlineOxExpectedAnswers` and rendered as individually-clickable spans by `renderInlineOxText`). `getAllLimbs()` flattens all questions into a single limb list for study sessions and stats, with an option to split inline-O/X limbs into individually-tracked pseudo-records (`makeInlineRecordId`).
- **Spaced repetition**: `nextReviewState()` (a lightweight SM-2-style ease/interval update), `reviewPriorityScore()`, and `isDueForReview()` drive the "復習" study mode.
- **Admin gating**: `isAdminUser()` checks the signed-in email against `window.APP_CONFIG.adminEmails` (set in `firebase-config.js`) — this only controls UI visibility for the 問題管理/管理者 pages; actual write permission is enforced server-side in `firestore.rules` against the hardcoded admin email.
- **Google sign-in is NOT FedCM.** `auth-module.js`'s `doGoogleLogin()` uses classic `firebase.auth.GoogleAuthProvider()` + `auth.signInWithPopup(provider)` (an OAuth popup, not Google Identity Services). The `<script src="https://accounts.google.com/gsi/client">` tag in `index.html` is loaded but unused — no `google.accounts.id.*` call exists anywhere in the codebase; the visible "Googleでログイン" button is a plain manually-created `<button>`.
- **Category label normalization**: `normalizeCategoryLabel()` is used everywhere categories are compared/displayed (filters, stats, badges) to reconcile old and new category naming schemes — if you add a new alias, add it to the `aliasMap` inside that function, not as a one-off string replace elsewhere.

### Firestore layout (see `firestore.rules`)

- `question_bank_years/{yearKey}` — shared question bank, public read, admin-only write.
- `question_sets/{uid}` — legacy per-user question snapshot (owner read/write).
- `study_stats/{uid}` — legacy study-time totals (owner read/write).
- `records/{uid}` — per-user answer records, study calendar, and session snapshot (current format is `docId == uid`; rules also accept a legacy `uid`-field format for backward compatibility).
