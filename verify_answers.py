#!/usr/bin/env python3
"""
verify_answers.py
○/× 問題（combo_ox）の正誤を検証・修正するスクリプト

【正解ソースの優先順位】
  1. HTMLキャッシュ  cache/html/<hash>.html
       スクレイパーが取得済みの gyosyo.info ページから直接パース（Gemini 不要）
  2. Gemini レスポンスキャッシュ  output/gemini_cache.json
       過去に Gemini API を呼んだ結果を再利用（API 呼び出し不要）
  3. Gemini API（リアルタイム呼び出し・要 API キー）

依存: python3 標準ライブラリ + requests
  pip install requests

環境変数:
  GEMINI_API_KEY   Gemini API キー（HTMLキャッシュ・Geminiキャッシュがない場合のみ必要）
  GEMINI_MODEL     使用モデル（省略時: gemini-2.0-flash）

使用例:
  # HTMLキャッシュ + Geminiキャッシュのみで確認（API不要）
  python3 verify_answers.py --cache-only --dry-run

  # 全問ドライラン（APIキーが必要）
  python3 verify_answers.py --dry-run

  # 特定の問題IDのみ検証・修正
  python3 verify_answers.py --ids R1-2 H27-3

  # カテゴリ絞り込み、確信度「高」のみ修正
  python3 verify_answers.py --category 憲法 --min-confidence 高

  # 50 肢だけ処理して一時停止、あとで --start-id で再開
  python3 verify_answers.py --year H27 --limit 50
  python3 verify_answers.py --year H27 --start-id H27-10

修正ログ: output/verification_corrections.json
Gemini レスポンスキャッシュ: output/gemini_cache.json
"""

import json
import os
import sys
import time
import argparse
import re
import datetime
import hashlib
from html import unescape
from pathlib import Path

try:
    import requests
except ImportError:
    print("エラー: requests が見つかりません。pip install requests")
    sys.exit(1)

# ── パス定義 ────────────────────────────────────────────────────
DATA_DIR           = Path(__file__).parent / 'output'
CACHE_HTML_DIR     = Path(__file__).parent / 'cache' / 'html'
GYOSYO_ALL_FILE    = DATA_DIR / 'gyosyo_all_questions.json'
OXQUIZ_FILE        = DATA_DIR / 'oxquiz_questions.json'
ALL_QUESTIONS_FILE = DATA_DIR / 'all_questions.json'
APP_JS_FILE        = Path(__file__).parent / 'app.js'
CORRECTIONS_LOG    = DATA_DIR / 'verification_corrections.json'
GEMINI_CACHE_FILE  = DATA_DIR / 'gemini_cache.json'

# ── Gemini 設定 ──────────────────────────────────────────────────
GEMINI_API_KEY   = os.environ.get('GEMINI_API_KEY', '')
GEMINI_MODEL     = os.environ.get('GEMINI_MODEL', 'gemini-2.0-flash')
GEMINI_API_BASE  = 'https://generativelanguage.googleapis.com/v1beta/models'
REQUEST_INTERVAL = 4.0   # seconds between API calls (rate limit safety)
MAX_RETRIES      = 3
RETRY_BACKOFF    = 15.0

CONFIDENCE_ORDER = ['高', '中', '低']

# ── ユーティリティ ───────────────────────────────────────────────
def load_json(path: Path) -> list | dict:
    for enc in ('utf-8', 'utf-8-sig'):
        try:
            with open(path, 'r', encoding=enc) as f:
                return json.load(f)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
    raise RuntimeError(f"JSON 読み込み失敗: {path}")


def save_json(path: Path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"  💾 保存: {path.name}")


def bump_bundle_version():
    text = APP_JS_FILE.read_text(encoding='utf-8')
    today = datetime.date.today().strftime('%Y-%m-%d')
    m = re.search(r"BUNDLE_VERSION = '([\d-]+-v(\d+))'", text)
    if m:
        old_ver, old_n = m.group(1), int(m.group(2))
        new_ver = f"{today}-v{old_n + 1}" if old_ver.startswith(today) else f"{today}-v1"
        APP_JS_FILE.write_text(
            text.replace(f"BUNDLE_VERSION = '{old_ver}'", f"BUNDLE_VERSION = '{new_ver}'"),
            encoding='utf-8',
        )
        print(f"  📦 BUNDLE_VERSION: {old_ver} → {new_ver}")


# ── ① HTMLキャッシュからの正解抽出 ──────────────────────────────
def _url_to_cache_path(url: str) -> Path:
    """URL の SHA256 ハッシュから cache/html/<hash>.html のパスを返す。"""
    h = hashlib.sha256(url.encode('utf-8')).hexdigest()
    return CACHE_HTML_DIR / f"{h}.html"


def _strip_html(html_fragment: str) -> str:
    t = re.sub(r'<script[^>]*>.*?</script>', '', html_fragment, flags=re.DOTALL|re.IGNORECASE)
    t = re.sub(r'<style[^>]*>.*?</style>',  '', t, flags=re.DOTALL|re.IGNORECASE)
    t = re.sub(r'<br\s*/?>', '\n', t, flags=re.IGNORECASE)
    t = re.sub(r'<[^>]+>', ' ', t)
    t = unescape(t)
    t = re.sub(r'[ \t　]+', ' ', t)
    return t.strip()


# gyosyo.info の個別問題ページに現れる各肢の正誤パターン
# 例: "ア・・・妥当でない" "ア・・・誤り" "ア○" "ア×" "（ア）誤り"
_KATA = 'アイウエオカキクケコ'
_CORRECT_WORDS  = ['妥当', '正しい', '適切', '正解', '○', 'まる']
_NEGATIVE_WORDS = ['でない', 'ではない', '誤り', '誤っ', '×', 'バツ', 'まちがい', '不適切', 'でなく']


def parse_limb_answers_from_html(html: str) -> dict[str, bool]:
    """
    gyosyo.info の個別問題ページ HTML から各肢（ア～オ）の正誤を抽出する。
    戻り値: {'ア': True, 'イ': False, 'ウ': True, ...}  (見つかった分だけ)
    """
    # <article> 要素を優先して取得
    m = re.search(r'<article[^>]*>(.*?)</article>', html, re.DOTALL|re.IGNORECASE)
    content = m.group(1) if m else html

    text = _strip_html(content)
    answers: dict[str, bool] = {}

    for line in text.split('\n'):
        line = line.strip()
        if not line:
            continue
        for kata in _KATA:
            # 行頭 or "（ア）" で始まる
            if not re.match(rf'^[（(]?{kata}[）)]?[・\s○×]', line):
                continue

            has_correct  = any(w in line for w in _CORRECT_WORDS)
            has_negative = any(w in line for w in _NEGATIVE_WORDS)

            if has_correct or has_negative:
                # "妥当でない" → negative が勝つ
                answers[kata] = has_correct and not has_negative
                break  # 1行に複数カタカナが来ることはほぼないが念のため

    return answers


def get_answer_from_html_cache(question_url: str,
                               limb_index: int,
                               limb_text: str) -> dict | None:
    """
    HTML キャッシュが存在すれば各肢の正誤を返す。
    戻り値: {"correct": bool, "confidence": "高", "reason": "HTMLキャッシュ", "source": "html"}
    または None（キャッシュなし / 判定不能）
    """
    if not question_url:
        return None

    cache_path = _url_to_cache_path(question_url)
    if not cache_path.exists():
        return None

    html = cache_path.read_text(encoding='utf-8', errors='replace')
    answers = parse_limb_answers_from_html(html)

    if not answers:
        return None

    # 肢のインデックス → カタカナ
    if limb_index < len(_KATA):
        kata = _KATA[limb_index]
        if kata in answers:
            return {
                'correct'   : answers[kata],
                'confidence': '高',
                'reason'    : f'HTMLキャッシュ（gyosyo.info）から抽出: {kata}={answers[kata]}',
                'source'    : 'html',
            }

    # フォールバック: limb_text の先頭文字がカタカナ肢ラベルと一致するか試みる
    first_kata = limb_text[0] if limb_text else ''
    if first_kata in _KATA and first_kata in answers:
        return {
            'correct'   : answers[first_kata],
            'confidence': '高',
            'reason'    : f'HTMLキャッシュ（gyosyo.info）から抽出: {first_kata}={answers[first_kata]}',
            'source'    : 'html',
        }

    return None


# ── ② Gemini レスポンスキャッシュ ────────────────────────────────
def load_gemini_cache() -> dict:
    if GEMINI_CACHE_FILE.exists():
        try:
            return load_json(GEMINI_CACHE_FILE)
        except Exception:
            pass
    return {}


def save_gemini_cache(cache: dict):
    save_json(GEMINI_CACHE_FILE, cache)


def gemini_cache_key(q_id: str, limb_id: str) -> str:
    return f"{q_id}::{limb_id}"


# ── ③ Gemini API 呼び出し ────────────────────────────────────────
SYSTEM_INSTRUCTION = (
    "あなたは行政書士試験の専門家です。"
    "日本の法律（憲法・行政法・民法・商法・基礎法学など）および"
    "最高裁判所の判例に基づき、問題文と肢の内容を正確に判定します。"
    "必ず有効な JSON のみで回答してください。JSON 以外の文章を出力してはいけません。"
)

USER_PROMPT_TEMPLATE = """\
以下の「大問文」と「肢の記述」について、肢の記述が法的・判例的に
正しい（true）か誤り（false）かを判定してください。

【大問文】
{question_text}

【肢の記述】
{limb_text}

以下の JSON 形式のみで回答（他の文章は一切不要）:
{{
  "correct": true または false,
  "confidence": "高" または "中" または "低",
  "reason": "判断理由を1〜2文で"
}}
"""


def call_gemini_api(question_text: str, limb_text: str,
                    model_name: str = GEMINI_MODEL) -> dict | None:
    """Gemini REST API に問い合わせて {"correct", "confidence", "reason"} を返す。"""
    if not GEMINI_API_KEY:
        return None

    url = f"{GEMINI_API_BASE}/{model_name}:generateContent?key={GEMINI_API_KEY}"
    prompt = USER_PROMPT_TEMPLATE.format(
        question_text=question_text.strip(),
        limb_text=limb_text.strip(),
    )
    payload = {
        "system_instruction": {"parts": [{"text": SYSTEM_INSTRUCTION}]},
        "contents"          : [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig"  : {
            "temperature"     : 0.1,
            "maxOutputTokens" : 512,
            "responseMimeType": "application/json",
        },
    }

    for attempt in range(MAX_RETRIES):
        try:
            resp = requests.post(url, json=payload, timeout=60)
            if resp.status_code == 429:
                wait = RETRY_BACKOFF * (attempt + 1)
                print(f"    ⚠️  レート制限 (429). {wait}s 待機...")
                time.sleep(wait)
                continue
            resp.raise_for_status()

            raw = resp.json()['candidates'][0]['content']['parts'][0]['text'].strip()
            m = re.search(r'\{.*?\}', raw, re.DOTALL)
            if not m:
                raise ValueError(f"JSON なし: {raw[:200]}")

            result = json.loads(m.group())
            if 'correct' not in result:
                raise ValueError(f"'correct' なし: {result}")
            result.setdefault('confidence', '低')
            result.setdefault('reason', '')
            result['source'] = 'gemini'
            return result

        except requests.exceptions.RequestException as e:
            if attempt < MAX_RETRIES - 1:
                wait = RETRY_BACKOFF * (attempt + 1)
                print(f"    ⚠️  通信エラー ({attempt+1}/{MAX_RETRIES}): {e} → {wait}s リトライ")
                time.sleep(wait)
            else:
                print(f"    ❌ 通信エラー（上限）: {e}")
                return None
        except (json.JSONDecodeError, ValueError, KeyError) as e:
            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_BACKOFF)
            else:
                print(f"    ❌ レスポンス解析失敗: {e}")
                return None

    return None


# ── 統合: 正解ソースを自動選択 ────────────────────────────────────
def get_answer(question_url: str, q_id: str, q_text: str,
               limb_id: str, limb_idx: int, limb_text: str,
               gemini_cache: dict, model_name: str,
               cache_only: bool) -> tuple[dict | None, bool]:
    """
    ① HTMLキャッシュ → ② Geminiキャッシュ → ③ Gemini API の順で正解を取得。
    戻り値: (result_dict or None, api_was_called: bool)
    """
    # ① HTML キャッシュ
    html_result = get_answer_from_html_cache(question_url, limb_idx, limb_text)
    if html_result:
        return html_result, False

    # ② Gemini レスポンスキャッシュ
    key = gemini_cache_key(q_id, limb_id)
    if key in gemini_cache:
        r = dict(gemini_cache[key])
        r['source'] = r.get('source', 'gemini_cache')
        return r, False

    # ③ キャッシュオンリーモードではここで終了
    if cache_only:
        return None, False

    # ④ Gemini API 呼び出し
    result = call_gemini_api(q_text, limb_text, model_name)
    api_called = result is not None
    if result:
        gemini_cache[key] = result   # キャッシュに保存
    return result, api_called


# ── フィルタリング ───────────────────────────────────────────────
def question_matches(q: dict, args) -> bool:
    if args.ids and q['id'] not in args.ids:
        return False
    if args.category:
        if args.category.lower() not in (q.get('category') or '').lower():
            return False
    if args.subject and q.get('subject') != args.subject:
        return False
    if args.year:
        src = q.get('source', '') + q.get('id', '')
        if not re.search(args.year, src, re.IGNORECASE):
            return False
    return True


def is_ox_limb(limb: dict) -> bool:
    return (
        not limb.get('options')
        and not limb.get('acceptedAnswers')
        and not limb.get('inlineOxWrong')
    )


# ── 各ファイルへの修正適用 ──────────────────────────────────────
def patch_oxquiz(oxquiz: list, parent_id: str, limb_idx: int,
                 new_correct: bool, reason: str) -> bool:
    entries = [q for q in oxquiz if q.get('parentId') == parent_id]
    if limb_idx >= len(entries):
        return False
    limbs = entries[limb_idx].get('limbs', [])
    if not limbs:
        return False
    limb = limbs[0]
    if limb.get('correct') == new_correct:
        return False
    limb['correct'] = new_correct
    if reason and not limb.get('explanation'):
        limb['explanation'] = reason
    return True


def patch_all_questions(all_qs: list, q_id: str, limb_id: str,
                        new_correct: bool, reason: str) -> bool:
    for q in all_qs:
        if q.get('id') != q_id:
            continue
        for limb in q.get('limbs', []):
            if limb.get('id') == limb_id:
                if limb.get('correct') == new_correct:
                    return False
                limb['correct'] = new_correct
                if reason and not limb.get('explanation'):
                    limb['explanation'] = reason
                return True
    return False


# ── メイン ──────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description='○/× 問題の正誤を検証・修正します（HTMLキャッシュ → Geminiキャッシュ → Gemini API）',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument('--dry-run', action='store_true',
                        help='変更を保存せず、修正案を表示するだけ')
    parser.add_argument('--cache-only', action='store_true',
                        help='HTMLキャッシュ・Geminiキャッシュのみ使用（Gemini API を呼ばない）')
    parser.add_argument('--ids', nargs='+', metavar='ID',
                        help='対象の問題ID (例: R1-2 H27-3)')
    parser.add_argument('--category', metavar='STR',
                        help='カテゴリで絞り込み（部分一致）')
    parser.add_argument('--subject', metavar='STR',
                        help='科目で絞り込み')
    parser.add_argument('--year', metavar='PATTERN',
                        help='年度パターン（例: H27 または R[12]）')
    parser.add_argument('--limit', type=int, default=None,
                        help='処理する最大肢数')
    parser.add_argument('--start-id', metavar='ID',
                        help='この問題IDから開始（中断後の再開用）')
    parser.add_argument('--min-confidence', default='中',
                        choices=['高', '中', '低'],
                        help='この確信度以上のみ修正を適用（default: 中）')
    parser.add_argument('--model', default=GEMINI_MODEL,
                        help=f'Gemini モデル（default: {GEMINI_MODEL}）')
    args = parser.parse_args()

    model_name = args.model

    # キャッシュオンリーモードでは API キー不要
    if not args.cache_only and not GEMINI_API_KEY:
        print("❌ 環境変数 GEMINI_API_KEY が設定されていません。")
        print("   export GEMINI_API_KEY='your-api-key'")
        print("   キャッシュのみ使用する場合は --cache-only オプションを追加してください。")
        sys.exit(1)

    print(f"🤖 モデル: {model_name}")
    if args.cache_only:
        print("📦 キャッシュオンリーモード（API 呼び出しなし）")

    print("📂 データ読み込み中...")
    gyosyo = load_json(GYOSYO_ALL_FILE)
    oxquiz = load_json(OXQUIZ_FILE)
    all_qs = load_json(ALL_QUESTIONS_FILE)
    gemini_cache = load_gemini_cache()

    # HTMLキャッシュの状況を表示
    html_cached_count = len(list(CACHE_HTML_DIR.glob('*.html'))) if CACHE_HTML_DIR.exists() else 0
    print(f"  HTMLキャッシュ: {html_cached_count} ファイル")
    print(f"  Geminiキャッシュ: {len(gemini_cache)} エントリ")

    targets = [
        q for q in gyosyo
        if q.get('answerType') == 'combo_ox' and question_matches(q, args)
    ]
    total_limbs = sum(
        len([l for l in q.get('limbs', []) if is_ox_limb(l)])
        for q in targets
    )
    print(f"  対象: {len(targets)} 問 / {total_limbs} 肢（combo_ox）")
    if args.limit:
        print(f"  上限: {args.limit} 肢")
    if args.dry_run:
        print("  ⚠️  --dry-run: ファイルへの書き込みは行いません")
    print()

    # 既存修正ログ
    corrections: list = []
    if CORRECTIONS_LOG.exists():
        try:
            corrections = load_json(CORRECTIONS_LOG)
            print(f"📋 既存ログ {len(corrections)} 件（追記）\n")
        except Exception:
            pass

    started      = (args.start_id is None)
    checked      = 0
    mismatches   = 0
    applied      = 0
    api_calls    = 0
    html_hits    = 0
    cache_hits   = 0
    gyosyo_dirty = oxquiz_dirty = all_qs_dirty = gemini_cache_dirty = False
    min_conf_idx = CONFIDENCE_ORDER.index(args.min_confidence)

    for q in targets:
        if not started:
            if q['id'] == args.start_id:
                started = True
            else:
                continue

        if args.limit is not None and checked >= args.limit:
            print(f"\n⏸  --limit {args.limit} 肢に達しました。")
            break

        q_id  = q['id']
        q_url = q.get('questionUrl', '')
        q_text = q.get('questionText', '')
        limbs  = [l for l in q.get('limbs', []) if is_ox_limb(l)]

        print(f"{'─'*64}")
        print(f"📝 [{q_id}]  {q.get('source','')}")

        for idx, limb in enumerate(limbs):
            if args.limit is not None and checked >= args.limit:
                break

            limb_id     = limb['id']
            limb_text   = limb.get('text', '')
            current_ans = bool(limb.get('correct', False))

            result, api_called = get_answer(
                q_url, q_id, q_text, limb_id, idx, limb_text,
                gemini_cache, model_name, args.cache_only,
            )

            # API 呼び出しがあった場合はレート制限のため待機
            if api_called:
                api_calls += 1
                gemini_cache_dirty = True
                time.sleep(REQUEST_INTERVAL)

            checked += 1

            if result is None:
                source_label = 'キャッシュなし' if args.cache_only else 'エラー'
                print(f"  [{idx+1}] ⏭  {limb_text[:50][:50]} → {source_label}")
                continue

            source     = result.get('source', 'gemini')
            gemini_ans = bool(result['correct'])
            confidence = result.get('confidence', '低')
            reason     = result.get('reason', '')
            conf_idx   = CONFIDENCE_ORDER.index(confidence) if confidence in CONFIDENCE_ORDER else 2

            # ソースアイコン
            src_icon = {'html': '🌐', 'gemini_cache': '💾', 'gemini': '🤖'}.get(source, '❓')

            if source == 'html':
                html_hits += 1
            elif source == 'gemini_cache':
                cache_hits += 1

            if gemini_ans != current_ans:
                mismatches += 1
                arrow = f"{'○' if current_ans else '×'} → {'○' if gemini_ans else '×'}"
                print(f"  [{idx+1}] ❌ {limb_text[:50]}...")
                print(f"       {arrow}  確信度:{confidence}  {src_icon} {reason}")

                entry = {
                    'question_id': q_id,
                    'limb_id'    : limb_id,
                    'limb_index' : idx,
                    'source'     : q.get('source', ''),
                    'limb_text'  : limb_text,
                    'old_correct': current_ans,
                    'new_correct': gemini_ans,
                    'confidence' : confidence,
                    'reason'     : reason,
                    'answer_src' : source,
                    'applied'    : False,
                }
                corrections.append(entry)

                if conf_idx <= min_conf_idx:
                    if not args.dry_run:
                        limb['correct'] = gemini_ans
                        if reason and not limb.get('explanation'):
                            limb['explanation'] = reason
                        gyosyo_dirty = True
                        if patch_oxquiz(oxquiz, q_id, idx, gemini_ans, reason):
                            oxquiz_dirty = True
                        if patch_all_questions(all_qs, q_id, limb_id, gemini_ans, reason):
                            all_qs_dirty = True
                        entry['applied'] = True
                        applied += 1
                        print(f"       ✏️  修正済み")
                    else:
                        print(f"       ✏️  [dry-run] 修正予定")
                else:
                    print(f"       ⏭  確信度 {confidence} < 閾値 {args.min_confidence}")
            else:
                print(f"  [{idx+1}] ✅ {'○' if current_ans else '×'}  {src_icon}  {limb_text[:55]}")

    # ── サマリー ─────────────────────────────────────────────────
    print(f"\n{'='*64}")
    print(f"📊 完了")
    print(f"  検証肢数    : {checked}")
    print(f"  HTMLキャッシュヒット: {html_hits}")
    print(f"  Geminiキャッシュヒット: {cache_hits}")
    print(f"  Gemini API 呼び出し: {api_calls}")
    print(f"  不一致      : {mismatches}")
    print(f"  修正適用    : {applied}" + ("（dry-run のため未保存）" if args.dry_run else ""))

    # Gemini キャッシュを保存（dry-run でも保存 = 再実行時に再利用できる）
    if gemini_cache_dirty:
        save_gemini_cache(gemini_cache)
        print(f"  💾 Geminiキャッシュ更新: {GEMINI_CACHE_FILE.name} ({len(gemini_cache)} エントリ)")

    # 修正ログを保存
    if corrections:
        save_json(CORRECTIONS_LOG, corrections)

    # データファイルへの書き込み
    if not args.dry_run and (gyosyo_dirty or oxquiz_dirty or all_qs_dirty):
        print("\n💾 保存中...")
        if gyosyo_dirty:
            save_json(GYOSYO_ALL_FILE, gyosyo)
        if oxquiz_dirty:
            save_json(OXQUIZ_FILE, oxquiz)
        if all_qs_dirty:
            save_json(ALL_QUESTIONS_FILE, all_qs)
        bump_bundle_version()
        print("\n✅ 完了")
    elif not args.dry_run:
        print("✅ 修正が必要な肢はありませんでした。")
    else:
        print("\n⚠️  --dry-run のためファイルへの書き込みはしていません。")


if __name__ == '__main__':
    main()
