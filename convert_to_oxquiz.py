#!/usr/bin/env python3
"""
convert_to_oxquiz.py
--------------------
APIなしで既存のスクレイプデータを1問1答（○×）形式に変換する。
生成された output/oxquiz_questions.json はアプリがそのまま読み込める。

使い方:
  python3 convert_to_oxquiz.py
  python3 convert_to_oxquiz.py --input output/gyosyo_all_questions.json
"""

import json
import re
import argparse
from pathlib import Path


DEFAULT_INPUT        = "output/gyosyo_all_questions.json"
DEFAULT_LIMB_INPUT   = "output/limb_questions.json"
DEFAULT_OUTPUT       = "output/oxquiz_questions.json"

# 穴埋め問題パターン（肢テキストが「ア：〇〇 イ：〇〇」形式）
FILL_BLANK_PAT = re.compile(
    r"^[アイウエオカキクケコ][:：\s].{1,20}\s+[アイウエオカキクケコ][:：\s]"
)

# 問題文の選択肢マーカー行をカット
KATA_MARKER = re.compile(
    r"(?m)^[ \t　]*[アイウエオカキクケコ]"
    r"[\s　.．、,::：\-]"
)
NUM_MARKER = re.compile(
    r"(?m)^[ \t　]*[1-5１-５][\s　.．、,::：]"
)


def get_lead_text(text: str) -> str:
    """問題文のリード文（肢の前まで）を抽出"""
    if not text:
        return ""
    cut = len(text)
    km = KATA_MARKER.search(text)
    nm = NUM_MARKER.search(text)
    if km and km.start() < cut:
        cut = km.start()
    if nm and nm.start() < cut:
        cut = nm.start()
    return text[:cut].rstrip()


def extract_year_num(q_id: str):
    m = re.match(r"^([A-Za-z][A-Za-z0-9]*)-(\d+)", q_id)
    if m:
        return m.group(1), int(m.group(2))
    return "", 0


def is_fill_blank_limb(text: str) -> bool:
    """肢テキストが「ア：〇〇 イ：〇〇」形式（穴埋め選択肢）かを判定"""
    return bool(FILL_BLANK_PAT.match(text or ""))


def make_statement(question_text: str, limb_text: str, answer_type: str) -> str:
    """
    肢テキストを1問1答用の陳述文にする。
    combo_ox: そのまま使用（既に独立した陳述文）
    choice:   問題文リード + 肢テキストで文脈を補う（穴埋め形式はそのまま）
    """
    if answer_type == "combo_ox":
        return limb_text.strip()

    # choice 問題
    if is_fill_blank_limb(limb_text):
        # 穴埋め選択肢はそのまま（「ア：人格 イ：有体物 ...」）
        lead = get_lead_text(question_text)
        if lead:
            # 「次の文章の空欄にあてはまる語句の組合せとして妥当なものはどれか」→ 前文抽出
            lead_short = lead.split("\n")[0][:60]
            return f"[{lead_short}…] 正しい組合せ: {limb_text.strip()}"
        return limb_text.strip()

    # 通常の choice 肢 → リード文を補う
    lead = get_lead_text(question_text)
    stmt = limb_text.strip()

    # リード文が意味ある場合は先頭に付与（短い場合のみ）
    if lead and len(lead) < 60 and not lead.rstrip().endswith(
        ("はどれか", "どれか", "いくつあるか", "いくつか")
    ):
        return f"{lead}について：{stmt}"

    return stmt


def convert(input_path: str, output_path: str) -> int:
    with open(input_path, encoding="utf-8-sig") as f:
        questions = json.load(f)

    ox_questions = []
    skipped_text = 0

    for q in questions:
        atype = q.get("answerType", "")
        if atype == "text":
            skipped_text += 1
            continue

        q_id = q["id"]
        year, qnum = extract_year_num(q_id)

        for i, limb in enumerate(q.get("limbs", [])):
            limb_id = limb.get("id", f"{q_id}-l{i}")
            correct  = bool(limb.get("correct", False))
            orig_exp = limb.get("explanation", "")
            stmt = make_statement(q.get("questionText", ""), limb.get("text", ""), atype)

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
                        "id": f"{limb_id}-ox",
                        "text": stmt,
                        "correct": correct,
                        "explanation": orig_exp,
                    }
                ],
                "questionUrl": q.get("questionUrl", ""),
            }
            ox_questions.append(ox_q)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(ox_questions, f, ensure_ascii=False, indent=2)

    print(f"変換完了: {len(ox_questions)} 問 → {output_path}")
    print(f"  (記述式 {skipped_text} 問はスキップ)")
    return len(ox_questions)


def convert_from_limb_questions(limb_input: str, output_path: str) -> int:
    """limb_questions.json（フラット形式）からネスト形式の1問1答へ変換。
    こちらは個別の解説が付いているため品質が高い。"""
    with open(limb_input, encoding="utf-8-sig") as f:
        limbs = json.load(f)

    ox_questions = []
    skipped = 0

    for entry in limbs:
        atype = entry.get("answerType", "")
        if atype == "text":
            skipped += 1
            continue

        limb_text = entry.get("limbText", "")
        if not limb_text:
            skipped += 1
            continue

        year_m = re.match(r"^([A-Za-z][A-Za-z0-9]*)-(\d+)", entry.get("parentId", ""))
        year = year_m.group(1) if year_m else entry.get("year", "")
        qnum = int(year_m.group(2)) if year_m else entry.get("questionNumber", 0)

        ox_q = {
            "id": f"{entry['id']}-ox",
            "parentId": entry.get("parentId", ""),
            "year": year,
            "questionNumber": qnum,
            "subject": entry.get("subject", "行政書士"),
            "category": entry.get("category", ""),
            "source": entry.get("source", ""),
            "answerType": "ox",
            "limbs": [
                {
                    "id": f"{entry['id']}-oxl",
                    "text": limb_text.strip(),
                    "correct": bool(entry.get("correct", False)),
                    "explanation": entry.get("explanation", ""),
                }
            ],
            "questionUrl": entry.get("questionUrl", ""),
        }
        ox_questions.append(ox_q)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(ox_questions, f, ensure_ascii=False, indent=2)

    print(f"変換完了（limb_questions）: {len(ox_questions)} 問 → {output_path}")
    print(f"  (スキップ {skipped} 件)")
    return len(ox_questions)


def main():
    parser = argparse.ArgumentParser(description="スクレイプデータを1問1答に変換（APIなし）")
    parser.add_argument("--input",  default=DEFAULT_INPUT,       help="入力JSONファイル（gyosyo_all_questions.json）")
    parser.add_argument("--limb",   default=DEFAULT_LIMB_INPUT,  help="肢別入力JSONファイル（limb_questions.json）")
    parser.add_argument("--output", default=DEFAULT_OUTPUT,      help="出力JSONファイル")
    parser.add_argument("--source", choices=["all", "limb"], default="limb",
                        help="all=gyosyo_all_questions.json から変換 / limb=limb_questions.json から変換（デフォルト）")
    args = parser.parse_args()

    if args.source == "limb":
        if not Path(args.limb).exists():
            print(f"Error: {args.limb} が見つかりません")
            return
        convert_from_limb_questions(args.limb, args.output)
    else:
        if not Path(args.input).exists():
            print(f"Error: {args.input} が見つかりません")
            return
        convert(args.input, args.output)


if __name__ == "__main__":
    main()
