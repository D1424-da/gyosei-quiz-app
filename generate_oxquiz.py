#!/usr/bin/env python3
"""
generate_oxquiz.py
------------------
行政書士試験の多択問題から1問1答（○×）形式をClaude APIで生成する。

使い方:
  export ANTHROPIC_API_KEY=sk-ant-xxxxx
  python3 generate_oxquiz.py [--input OUTPUT/gyosyo_all_questions.json] [--limit 50]

出力: output/api_oxquiz_questions.json
再開: 進捗は output/api_oxquiz_progress.json に保存。途中で止めても再実行で続きから。
"""

import json
import os
import sys
import time
import re
import argparse
from pathlib import Path

try:
    import anthropic
except ImportError:
    print("Error: anthropic パッケージが未インストールです")
    print("  pip install anthropic")
    sys.exit(1)

# ---- 設定 ----
DEFAULT_INPUT   = "output/gyosyo_all_questions.json"
DEFAULT_OUTPUT  = "output/api_oxquiz_questions.json"
PROGRESS_FILE   = "output/api_oxquiz_progress.json"
MODEL           = "claude-haiku-4-5-20251001"
MAX_TOKENS      = 4096
REQUEST_DELAY   = 0.6   # sec between API calls (rate limit buffer)

SYSTEM_PROMPT = """あなたは行政書士試験の問題作成専門家です。
与えられた択一式問題の各肢（選択肢）を、文脈なしで単独で理解できる1問1答（○×）問題に変換してください。

出力形式: JSON配列のみ（他のテキスト不要）
[
  {
    "limbIndex": 0,
    "text": "独立して理解できる形式の陳述文（断定形、「か」で終わらない）",
    "correct": true,
    "explanation": "正誤の理由を法的に正確かつ簡潔に（2～4文）"
  },
  ...
]

変換のルール:
- 各肢の陳述文が不完全な場合（元の問題文の文脈に依存している場合）は、必要な情報を補足して完全な文にする
- 陳述文は「〇〇は〇〇である」「〇〇の場合、〇〇となる」のような断定形にする
- 「次のうち」「次の記述のうち」などの問題文フレームは使わない
- 解説は受験対策として有用な内容にし、関連条文や判例があれば言及する
- 正誤判定: 元のデータの correct フラグをそのまま使用する"""


def load_progress():
    if Path(PROGRESS_FILE).exists():
        with open(PROGRESS_FILE, encoding="utf-8") as f:
            return json.load(f)
    return {"processed_ids": [], "results": []}


def save_progress(progress):
    with open(PROGRESS_FILE, "w", encoding="utf-8") as f:
        json.dump(progress, f, ensure_ascii=False, indent=2)


def extract_year_num(q_id):
    m = re.match(r"^([A-Za-z][A-Za-z0-9]*)-(\d+)", q_id)
    if m:
        return m.group(1), int(m.group(2))
    return "", 0


def build_user_prompt(q):
    """問題→APIプロンプト用テキスト"""
    lines = [
        f"問題文: {q['questionText']}",
        f"カテゴリ: {q.get('category', '')} / {q.get('source', '')}",
        f"問題種別: {q.get('answerType', '')}",
        "",
        "各肢（correct=Trueは陳述が正しい、Falseは誤り）:",
    ]
    for i, limb in enumerate(q.get("limbs", [])):
        lines.append(f"肢{i} (correct={limb.get('correct', '?')}): {limb.get('text', '')}")
    return "\n".join(lines)


def call_api(client, q):
    """Claude APIを呼び出して1問1答リストを返す"""
    prompt = build_user_prompt(q)
    try:
        resp = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": prompt}],
        )
        raw = resp.content[0].text.strip()
        # JSON ブロック抽出
        if "```json" in raw:
            raw = raw.split("```json")[1].split("```")[0].strip()
        elif "```" in raw:
            raw = raw.split("```")[1].split("```")[0].strip()
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"    JSON parse error: {e}")
        return None
    except Exception as e:
        print(f"    API error: {e}")
        return None


def make_ox_question(q, limb_data, limb_index):
    """個別の1問1答レコードを作成"""
    year, qnum = extract_year_num(q["id"])
    original_limb = q["limbs"][limb_index] if limb_index < len(q["limbs"]) else {}
    return {
        "id": f"{q['id']}-ox{limb_index}",
        "parentId": q["id"],
        "year": year,
        "questionNumber": qnum,
        "subject": q.get("subject", "行政書士"),
        "category": q.get("category", ""),
        "source": q.get("source", ""),
        "answerType": "ox",
        "limbs": [
            {
                "id": f"{original_limb.get('id', q['id'])}-ox",
                "text": limb_data.get("text", original_limb.get("text", "")),
                "correct": limb_data.get("correct", original_limb.get("correct", False)),
                "explanation": limb_data.get("explanation", original_limb.get("explanation", "")),
            }
        ],
        "questionUrl": q.get("questionUrl", ""),
    }


def process_question(client, q):
    """1問をAPI処理して1問1答リストを返す"""
    if q.get("answerType") == "text":
        return []  # 記述式は今回スキップ

    api_limbs = call_api(client, q)
    if not api_limbs:
        return None

    results = []
    for ld in api_limbs:
        idx = ld.get("limbIndex", 0)
        if idx < len(q.get("limbs", [])):
            results.append(make_ox_question(q, ld, idx))

    return results


def main():
    parser = argparse.ArgumentParser(description="Claude APIで1問1答を生成")
    parser.add_argument("--input", default=DEFAULT_INPUT, help="入力JSONファイル")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="出力JSONファイル")
    parser.add_argument("--limit", type=int, default=0, help="処理する問題数の上限（0=全問）")
    parser.add_argument("--category", default="", help="特定カテゴリのみ処理")
    args = parser.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("Error: ANTHROPIC_API_KEY 環境変数が設定されていません")
        print("  export ANTHROPIC_API_KEY=sk-ant-xxxxx")
        sys.exit(1)

    client = anthropic.Anthropic(api_key=api_key)

    print(f"読み込み: {args.input}")
    with open(args.input, encoding="utf-8-sig") as f:
        questions = json.load(f)
    print(f"  {len(questions)} 問")

    # フィルタ
    if args.category:
        questions = [q for q in questions if args.category in q.get("category", "")]
        print(f"  カテゴリ '{args.category}' でフィルタ: {len(questions)} 問")
    if args.limit > 0:
        questions = questions[: args.limit]
        print(f"  上限 {args.limit} 問")

    # 進捗読み込み
    progress = load_progress()
    processed_ids = set(progress["processed_ids"])
    results = progress["results"]
    print(f"既処理: {len(processed_ids)} 問 / 未処理: {len(questions) - len(processed_ids)} 問")

    pending = [q for q in questions if q["id"] not in processed_ids]

    for i, q in enumerate(pending):
        print(f"[{i+1}/{len(pending)}] {q['id']} ({q.get('category', '')} / {q.get('answerType', '')})", end=" ", flush=True)
        ox = process_question(client, q)
        if ox is None:
            print("ERROR - スキップ")
        elif len(ox) == 0:
            processed_ids.add(q["id"])
            print(f"スキップ ({q.get('answerType')})")
        else:
            results.extend(ox)
            processed_ids.add(q["id"])
            progress["processed_ids"] = list(processed_ids)
            progress["results"] = results
            print(f"OK ({len(ox)} 問生成)")
            if (i + 1) % 20 == 0:
                save_progress(progress)
                print(f"  [中間保存: 累計 {len(results)} 問]")

        time.sleep(REQUEST_DELAY)

    save_progress(progress)

    out_path = args.output
    print(f"\n書き出し: {out_path}")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"完了: {len(results)} 問を出力しました")


if __name__ == "__main__":
    main()
