#!/usr/bin/env python3
"""
verify_answers.py
Gemini API を使って ○/× 問題（combo_ox）の正誤を検証・修正するスクリプト

依存: python3 標準ライブラリ + requests
  pip install requests   (通常はインストール済み)

環境変数:
  GEMINI_API_KEY   Gemini API キー（必須）
  GEMINI_MODEL     使用モデル（省略時: gemini-2.0-flash）

使用例:
  # 全問をドライラン（変更なし）で確認
  python3 verify_answers.py --dry-run

  # 特定の問題IDのみ検証
  python3 verify_answers.py --ids R1-2 H27-3

  # カテゴリを絞って検証（確信度「高」のみ修正）
  python3 verify_answers.py --category 憲法 --min-confidence 高

  # 年度を絞って一度に 50 肢まで処理
  python3 verify_answers.py --year H27 --limit 50

  # 途中から再開（指定IDの問題から）
  python3 verify_answers.py --start-id H27-10

修正ログは output/verification_corrections.json に保存されます。
"""

import json
import os
import sys
import time
import argparse
import re
import datetime
from pathlib import Path

# requests は標準的な環境にインストール済みのはず
try:
    import requests
except ImportError:
    print("エラー: requests が見つかりません。pip install requests")
    sys.exit(1)

# ── 設定 ────────────────────────────────────────────────────────
GEMINI_API_KEY   = os.environ.get('GEMINI_API_KEY', '')
GEMINI_MODEL     = os.environ.get('GEMINI_MODEL', 'gemini-2.0-flash')
GEMINI_API_BASE  = 'https://generativelanguage.googleapis.com/v1beta/models'

# 無料枠: 15 RPM / 100万 TPM を超えないよう余裕を持って待機
REQUEST_INTERVAL_SEC = 4.0
MAX_RETRIES          = 3
RETRY_BACKOFF_SEC    = 15.0

DATA_DIR           = Path(__file__).parent / 'output'
GYOSYO_ALL_FILE    = DATA_DIR / 'gyosyo_all_questions.json'
OXQUIZ_FILE        = DATA_DIR / 'oxquiz_questions.json'
ALL_QUESTIONS_FILE = DATA_DIR / 'all_questions.json'
APP_JS_FILE        = Path(__file__).parent / 'app.js'
CORRECTIONS_LOG    = DATA_DIR / 'verification_corrections.json'

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
    """app.js の BUNDLE_VERSION を更新してブラウザキャッシュをクリアさせる。"""
    text = APP_JS_FILE.read_text(encoding='utf-8')
    today = datetime.date.today().strftime('%Y-%m-%d')
    m = re.search(r"BUNDLE_VERSION = '([\d-]+-v(\d+))'", text)
    if m:
        old_ver = m.group(1)
        old_n   = int(m.group(2))
        new_ver = f"{today}-v{old_n + 1}" if old_ver.startswith(today) else f"{today}-v1"
        APP_JS_FILE.write_text(
            text.replace(f"BUNDLE_VERSION = '{old_ver}'", f"BUNDLE_VERSION = '{new_ver}'"),
            encoding='utf-8',
        )
        print(f"  📦 BUNDLE_VERSION: {old_ver} → {new_ver}")


# ── Gemini REST API ──────────────────────────────────────────────
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
    """
    Gemini REST API に問い合わせて正誤を返す。
    {"correct": bool, "confidence": str, "reason": str} または None。
    """
    url = f"{GEMINI_API_BASE}/{model_name}:generateContent?key={GEMINI_API_KEY}"
    prompt = USER_PROMPT_TEMPLATE.format(
        question_text=question_text.strip(),
        limb_text=limb_text.strip(),
    )
    payload = {
        "system_instruction": {
            "parts": [{"text": SYSTEM_INSTRUCTION}]
        },
        "contents": [
            {"role": "user", "parts": [{"text": prompt}]}
        ],
        "generationConfig": {
            "temperature": 0.1,       # 決定論的に
            "maxOutputTokens": 512,
            "responseMimeType": "application/json",
        },
    }

    for attempt in range(MAX_RETRIES):
        try:
            resp = requests.post(url, json=payload, timeout=60)
            if resp.status_code == 429:
                wait = RETRY_BACKOFF_SEC * (attempt + 1)
                print(f"    ⚠️  レート制限 (429). {wait}s 待機...")
                time.sleep(wait)
                continue
            resp.raise_for_status()

            data = resp.json()
            raw_text = (
                data['candidates'][0]['content']['parts'][0]['text']
                .strip()
            )

            # JSON 抽出（```json ... ``` ブロックにも対応）
            json_match = re.search(r'\{.*?\}', raw_text, re.DOTALL)
            if not json_match:
                raise ValueError(f"JSON が見つかりません: {raw_text[:200]}")

            result = json.loads(json_match.group())
            if 'correct' not in result:
                raise ValueError(f"'correct' フィールドなし: {result}")
            result.setdefault('confidence', '低')
            result.setdefault('reason', '')
            return result

        except requests.exceptions.RequestException as e:
            if attempt < MAX_RETRIES - 1:
                wait = RETRY_BACKOFF_SEC * (attempt + 1)
                print(f"    ⚠️  通信エラー (試行 {attempt+1}/{MAX_RETRIES}): {e} → {wait}s 後リトライ")
                time.sleep(wait)
            else:
                print(f"    ❌ 通信エラー（上限到達）: {e}")
                return None
        except (json.JSONDecodeError, ValueError, KeyError) as e:
            if attempt < MAX_RETRIES - 1:
                wait = RETRY_BACKOFF_SEC
                print(f"    ⚠️  レスポンス解析エラー (試行 {attempt+1}/{MAX_RETRIES}): {e} → {wait}s 後リトライ")
                time.sleep(wait)
            else:
                print(f"    ❌ レスポンス解析失敗: {e}")
                return None

    return None


# ── フィルタリング ───────────────────────────────────────────────
def question_matches(q: dict, args) -> bool:
    if args.ids and q['id'] not in args.ids:
        return False
    if args.category:
        cat = (q.get('category') or '').lower()
        if args.category.lower() not in cat:
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
    """oxquiz_questions.json の対応エントリを更新する。"""
    entries = [q for q in oxquiz if q.get('parentId') == parent_id]
    if limb_idx >= len(entries):
        return False
    limb = entries[limb_idx]['limbs'][0] if entries[limb_idx].get('limbs') else None
    if limb is None or limb.get('correct') == new_correct:
        return False
    limb['correct'] = new_correct
    if reason and not limb.get('explanation'):
        limb['explanation'] = reason
    return True


def patch_all_questions(all_qs: list, q_id: str, limb_id: str,
                        new_correct: bool, reason: str) -> bool:
    """all_questions.json の対応肢を更新する。"""
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
        description='Gemini API で ○/× 問題の正誤を検証・修正します',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument('--dry-run', action='store_true',
                        help='変更を保存せず、修正案を表示するだけ')
    parser.add_argument('--ids', nargs='+', metavar='ID',
                        help='対象の問題ID (例: R1-2 H27-3)')
    parser.add_argument('--category', metavar='STR',
                        help='カテゴリで絞り込み（部分一致、例: 憲法）')
    parser.add_argument('--subject', metavar='STR',
                        help='科目で絞り込み（例: 行政書士）')
    parser.add_argument('--year', metavar='PATTERN',
                        help='年度パターン（例: H27 または R[12]）')
    parser.add_argument('--limit', type=int, default=None,
                        help='処理する最大肢数')
    parser.add_argument('--start-id', metavar='ID',
                        help='この問題IDから開始（中断後の再開用）')
    parser.add_argument('--min-confidence', default='中',
                        choices=['高', '中', '低'],
                        help='この確信度以上の場合のみ修正を適用（default: 中）')
    parser.add_argument('--model', default=GEMINI_MODEL,
                        help=f'使用する Gemini モデル（default: {GEMINI_MODEL}）')
    args = parser.parse_args()

    # API キー確認
    if not GEMINI_API_KEY:
        print("❌ エラー: 環境変数 GEMINI_API_KEY が設定されていません。")
        print("   export GEMINI_API_KEY='your-api-key'")
        sys.exit(1)

    # モデル上書き
    model_name = args.model

    print(f"🤖 Gemini モデル: {model_name}")
    print(f"📂 データ読み込み中...")

    gyosyo = load_json(GYOSYO_ALL_FILE)
    oxquiz = load_json(OXQUIZ_FILE)
    all_qs = load_json(ALL_QUESTIONS_FILE)

    # combo_ox 問題のみ対象（各肢が独立した ○/× 値を持つ形式）
    targets = [
        q for q in gyosyo
        if q.get('answerType') == 'combo_ox' and question_matches(q, args)
    ]
    total_limbs = sum(
        len([l for l in q.get('limbs', []) if is_ox_limb(l)])
        for q in targets
    )

    print(f"  gyosyo_all: {len(gyosyo)} 問  oxquiz: {len(oxquiz)} 問")
    print(f"  対象: {len(targets)} 問 / {total_limbs} 肢（combo_ox）")
    if args.limit:
        print(f"  上限: {args.limit} 肢")
    if args.dry_run:
        print("  ⚠️  --dry-run: ファイルへの書き込みは行いません")
    print()

    # 既存ログがあれば追記
    corrections: list = []
    if CORRECTIONS_LOG.exists():
        try:
            corrections = load_json(CORRECTIONS_LOG)
            print(f"📋 既存ログ {len(corrections)} 件（追記モード）\n")
        except Exception:
            pass

    started          = (args.start_id is None)
    checked          = 0
    mismatches       = 0
    applied          = 0
    gyosyo_dirty     = False
    oxquiz_dirty     = False
    all_qs_dirty     = False
    min_conf_idx     = CONFIDENCE_ORDER.index(args.min_confidence)

    for q in targets:
        if not started:
            if q['id'] == args.start_id:
                started = True
            else:
                continue

        if args.limit is not None and checked >= args.limit:
            print(f"\n⏸  --limit {args.limit} 肢に達しました。")
            break

        q_id   = q['id']
        q_text = q.get('questionText', '')
        limbs  = [l for l in q.get('limbs', []) if is_ox_limb(l)]

        print(f"{'─'*64}")
        print(f"📝 [{q_id}]  {q.get('source','')}")
        print(f"   大問: {q_text[:90].rstrip()}{'...' if len(q_text) > 90 else ''}")

        for idx, limb in enumerate(limbs):
            if args.limit is not None and checked >= args.limit:
                break

            limb_id     = limb['id']
            limb_text   = limb.get('text', '')
            current_ans = bool(limb.get('correct', False))

            print(f"\n  [{idx+1}/{len(limbs)}] {limb_text[:70]}{'...' if len(limb_text) > 70 else ''}")
            print(f"  現在: {'○' if current_ans else '×'}", end='  ')

            result = call_gemini_api(q_text, limb_text, model_name)
            time.sleep(REQUEST_INTERVAL_SEC)
            checked += 1

            if result is None:
                print("⚠️  API エラー → スキップ")
                continue

            gemini_ans  = bool(result['correct'])
            confidence  = result.get('confidence', '低')
            reason      = result.get('reason', '')
            conf_idx    = CONFIDENCE_ORDER.index(confidence) if confidence in CONFIDENCE_ORDER else 2

            if gemini_ans != current_ans:
                mismatches += 1
                arrow = f"{'○' if current_ans else '×'} → {'○' if gemini_ans else '×'}"
                print(f"❌ 不一致: {arrow}  確信度: {confidence}")
                print(f"  理由: {reason}")

                entry = {
                    'question_id' : q_id,
                    'limb_id'     : limb_id,
                    'limb_index'  : idx,
                    'source'      : q.get('source', ''),
                    'limb_text'   : limb_text,
                    'old_correct' : current_ans,
                    'new_correct' : gemini_ans,
                    'confidence'  : confidence,
                    'reason'      : reason,
                    'applied'     : False,
                }
                corrections.append(entry)

                # 確信度が閾値以上なら適用
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
                        print(f"  ✏️  修正済み")
                    else:
                        print(f"  ✏️  [dry-run] 修正予定")
                else:
                    print(f"  ⏭  確信度 {confidence} < 閾値 {args.min_confidence} → スキップ")
            else:
                print(f"✅ 一致  確信度: {confidence}")

    # ── サマリー ─────────────────────────────────────────────────
    print(f"\n{'='*64}")
    print(f"📊 完了  検証: {checked} 肢  不一致: {mismatches}  適用: {applied}")
    if args.dry_run:
        print("   （--dry-run のためファイルは変更していません）")

    # ログ保存（dry-run でも保存）
    if corrections:
        save_json(CORRECTIONS_LOG, corrections)

    # ファイル書き込み
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


if __name__ == '__main__':
    main()
