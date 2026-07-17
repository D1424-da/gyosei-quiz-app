#!/usr/bin/env python3
"""
convert_to_oxquiz.py
--------------------
APIなしで既存のスクレイプデータを1問1答（○×）形式に変換する。

スキップする問題:
  - 記述式 (answerType=text)
  - 空欄補充（語句組合せ）
  - 判例文・長文読解（下線部の組合せ選択）
  - 肢テキストが語句組合せ形式のもの（「ア：〇〇 イ：〇〇」「ア・ウ」など）

使い方:
  python convert_to_oxquiz.py
  python convert_to_oxquiz.py --input output/gyosyo_all_questions.json
"""

import json
import re
import argparse
from pathlib import Path

DEFAULT_INPUT  = "output/gyosyo_all_questions.json"
DEFAULT_OUTPUT = "output/oxquiz_questions.json"

# 肢テキストが「語句の組合せ答え」になっているパターン
COMBO_ANS_PAT = re.compile(
    r"^[アイウエオ][:：]"          # ア：〇〇 形式
    r"|[ア-オ]・[ア-オ]"           # ア・ウ 形式
    r"|[A-EＡ-Ｅ][とや][A-EＡ-Ｅ]" # AとB / AやB 形式
    r"|の相談と"                    # AとBの相談 形式
    r"|正しい組合せ"
)


def should_skip_question(q: dict) -> tuple[bool, str]:
    """スキップすべき問題かどうかを判定。(skip, reason) を返す"""
    at = q.get("answerType", "")
    qt = q.get("questionText", "")

    if at == "text":
        return True, "記述式"

    # 空欄補充（語句組合せ）: 「空欄［ア］〜」「空欄にあてはまる語句の組合せ」
    if "空欄" in qt and re.search(r"[アイウエオ]|［", qt):
        return True, "空欄補充"

    # 判例文・長文読解で下線部組合せを選ぶ問題
    if ("次の文章" in qt or "文章は" in qt) and "下線" in qt:
        return True, "判例文（下線部組合せ）"

    return False, ""


def is_valid_limb_text(text: str) -> bool:
    """肢テキストがO×文として使えるか（語句組合せ答えを除外）"""
    return not bool(COMBO_ANS_PAT.search(text or ""))


def extract_year_num(q_id: str):
    m = re.match(r"^([A-Za-z][A-Za-z0-9]*)-(\d+)", q_id)
    if m:
        return m.group(1), int(m.group(2))
    return "", 0


def convert(input_path: str, output_path: str) -> None:
    with open(input_path, encoding="utf-8-sig") as f:
        questions = json.load(f)

    ox_questions = []
    skip_counts = {}
    invalid_limb_count = 0

    for q in questions:
        skip, reason = should_skip_question(q)
        if skip:
            skip_counts[reason] = skip_counts.get(reason, 0) + 1
            continue

        q_id = q["id"]
        year, qnum = extract_year_num(q_id)

        for i, limb in enumerate(q.get("limbs", [])):
            limb_text = limb.get("text", "").strip()

            if not limb_text:
                continue

            if not is_valid_limb_text(limb_text):
                invalid_limb_count += 1
                continue

            ox_q = {
                "id": f"{q_id}-ox{i}",
                "parentId": q_id,
                "year": year,
                "questionNumber": qnum,
                "subject": q.get("subject", "行政書士"),
                "category": q.get("category", ""),
                "source": q.get("source", ""),
                "answerType": "ox",
                "limbs": [
                    {
                        "id": f"{limb.get('id', q_id + '-l' + str(i))}-ox",
                        "text": limb_text,
                        "correct": bool(limb.get("correct", False)),
                        "explanation": "",
                    }
                ],
                "questionUrl": q.get("questionUrl", ""),
            }
            ox_questions.append(ox_q)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(ox_questions, f, ensure_ascii=False, indent=2)

    print(f"変換完了: {len(ox_questions)} 問 → {output_path}")
    print("スキップ内訳:")
    for reason, count in skip_counts.items():
        print(f"  {reason}: {count} 問")
    print(f"  語句組合せ肢（除外）: {invalid_limb_count} 件")


def main():
    parser = argparse.ArgumentParser(description="スクレイプデータを1問1答に変換（APIなし）")
    parser.add_argument("--input",  default=DEFAULT_INPUT,  help="入力JSONファイル")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="出力JSONファイル")
    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"Error: {args.input} が見つかりません")
        return

    convert(args.input, args.output)


if __name__ == "__main__":
    main()
