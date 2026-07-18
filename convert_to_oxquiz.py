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

# 肢テキストが「数を答える」形式（「一つ」「二つ」「なし」等）
COUNT_ANS_PAT = re.compile(r"^[一二三四五六七八九十]つ$|^[0-9０-９]つ$|^なし$|^ない$")

# questionText自体を参照しなければ肢を判断できない問題
REF_QT_PAT = re.compile(
    r"この判決|この文章|この規定に関する|本判決"
    r"|以下の文章|以下の会話|下記の規定"
    r"|この文章の趣旨|次の文章の趣旨"
)

# 事例問題の人物・物件記号パターン
SCENARIO_PAT = re.compile(
    r"[AＡBＢCＣXＸYＹ][はがをにのとも]"  # A・B・X・Y などの当事者
    r"|甲建物|甲土地|甲会社|甲機械|甲動産"  # 甲〇〇 の目的物
    r"|[AＡBＢ]社"                          # A社・B社
)

# 「本件〜」エイリアス定義パターン（R6-11のような問題）
ALIAS_DEF_PAT = re.compile(r'（以下[「『](本件\S{1,10})[」』]という）')

# 正誤が逆転するネガティブ問のパターン
NEGATIVE_PAT = re.compile(r'誤り|妥当でない|正しくない|誤っている|不適切|間違い')


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
    """肢テキストがO×文として使えるか（語句組合せ・数量答えを除外）"""
    t = text or ""
    return not (COMBO_ANS_PAT.search(t) or COUNT_ANS_PAT.match(t.strip()))


def extract_year_num(q_id: str):
    m = re.match(r"^([A-Za-z][A-Za-z0-9]*)-(\d+)", q_id)
    if m:
        return m.group(1), int(m.group(2))
    return "", 0


def get_scenario_text(q: dict) -> str:
    """事例問題の場合に scenarioText（問題の前提状況）を返す。不要なら空文字。"""
    qt = q.get("questionText", "")
    if len(qt) <= 100:
        return ""

    # パターン1: 「本件処分」のようなエイリアスを定義し、肢でそのエイリアスを使用
    alias_match = ALIAS_DEF_PAT.search(qt)
    if alias_match:
        alias = alias_match.group(1)
        if any(alias in l.get("text", "") for l in q.get("limbs", [])):
            return qt

    # パターン2: 問題文と肢の両方に当事者記号（A・B・甲など）が登場
    if SCENARIO_PAT.search(qt):
        if any(SCENARIO_PAT.search(l.get("text", "")) for l in q.get("limbs", [])):
            return qt

    # パターン3: 「この判決」「この文章の趣旨」等、問題文本体を参照して肢を判断する問題
    if REF_QT_PAT.search(qt[:300]):
        return qt

    return ""


def needs_correct_inversion(q: dict) -> bool:
    """choiceで1肢だけcorrect=Trueかつネガティブ問の場合、O×変換時にcorrectを反転する必要がある。
    この場合 correct=True は「正解選択肢（=誤り肢）」を意味するため。"""
    if q.get("answerType") != "choice":
        return False
    trues = sum(1 for l in q.get("limbs", []) if l.get("correct"))
    if trues != 1:
        return False
    return bool(NEGATIVE_PAT.search(q.get("questionText", "")))


def convert(input_path: str, output_path: str) -> None:
    with open(input_path, encoding="utf-8-sig") as f:
        questions = json.load(f)

    ox_questions = []
    skip_counts = {}
    invalid_limb_count = 0
    scenario_count = 0
    inversion_count = 0

    for q in questions:
        skip, reason = should_skip_question(q)
        if skip:
            skip_counts[reason] = skip_counts.get(reason, 0) + 1
            continue

        q_id = q["id"]
        year, qnum = extract_year_num(q_id)
        scenario_text = get_scenario_text(q)
        if scenario_text:
            scenario_count += 1

        invert = needs_correct_inversion(q)
        if invert:
            inversion_count += 1

        for i, limb in enumerate(q.get("limbs", [])):
            limb_text = limb.get("text", "").strip()

            if not limb_text:
                continue

            if not is_valid_limb_text(limb_text):
                invalid_limb_count += 1
                continue

            raw_correct = bool(limb.get("correct", False))
            correct = (not raw_correct) if invert else raw_correct

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
                        "correct": correct,
                        "explanation": "",
                    }
                ],
                "questionUrl": q.get("questionUrl", ""),
            }
            if scenario_text:
                ox_q["scenarioText"] = scenario_text
            ox_questions.append(ox_q)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(ox_questions, f, ensure_ascii=False, indent=2)

    print(f"変換完了: {len(ox_questions)} 問 → {output_path}")
    print("スキップ内訳:")
    for reason, count in skip_counts.items():
        print(f"  {reason}: {count} 問")
    print(f"  語句組合せ肢（除外）: {invalid_limb_count} 件")
    print(f"scenarioText付与: {scenario_count} 問")
    print(f"correct反転（ネガティブ問）: {inversion_count} 問")


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
