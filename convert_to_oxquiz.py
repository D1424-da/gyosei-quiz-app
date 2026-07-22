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
    r"^[アイウエオ][:：]"  # ア：〇〇 形式
    r"|[ア-オ]・[ア-オ]"  # ア・ウ 形式
    r"|の相談と"            # AとBの相談 形式（H21-28など）
    r"|正しい組合せ"
)

# 肢テキストが「数を答える」形式（「一つ」「二つ」「なし」等）
COUNT_ANS_PAT = re.compile(r"^[一二三四五六七八九十]つ$|^[0-9０-９]つ$|^なし$|^ない$")

# 法改正で成立しなくなった肢（「法改正により削除」「法改正により回答不要」）
# ※「法改正により、〜」のような通常の文は読点が入るためマッチしない
JUNK_LIMB_PAT = re.compile(r"法改正により(削除|回答不要)")

# questionText自体を参照しなければ肢を判断できない問題
REF_QT_PAT = re.compile(
    r"この判決|この文章|この規定に関する|本判決"
    r"|以下の文章|以下の会話|下記の規定"
    r"|この文章の趣旨|次の文章の趣旨"
    r"|次の文章|次に掲げる条文"
)

# 問題文をscenarioTextとして必ず付与する問題（自動判定で拾えないもの）
SCENARIO_FORCE_IDS = {
    "H30-6",   # 政党Xの公選法改正提案（ア～エ）が問題文にしかない
}

# 事例問題の人物・物件記号パターン
SCENARIO_PAT = re.compile(
    r"[AＡBＢCＣXＸYＹ][はがをにのとも]"  # A・B・X・Y などの当事者
    r"|甲建物|甲土地|甲会社|甲機械|甲動産"  # 甲〇〇 の目的物
    r"|[AＡBＢ]社"                          # A社・B社
)

# 「本件〜」エイリアス定義パターン（R6-11のような問題）
ALIAS_DEF_PAT = re.compile(r'（以下[「『](本件\S{1,10})[」』]という）')

# 肢が名詞句・語句のみの問題に付与する述語
# 値に {} を含む場合はテンプレート（{} に肢テキストが入る）、
# 含まない場合は「[肢テキスト]は、[述語]。」という断定文を作る
NOUN_PHRASE_PREDICATES: dict = {
    "R1-56":  "主としてアナログ方式で送られている",
    "R3-36":  "営業として行わない場合には商行為とならない",
    "R5-13":  "努力義務として規定されている",
    "R5-30":  "他の連帯債務者に対して効力が生じない",
    "H21-13": "私人間紛争の裁定的性格を有する行政審判に該当する",
    "H23-10": "伝統的に行政裁量が広く認められると解されてきた行政行為である",
    "H30-53": "風適法による許可または届出の対象となっていない",
    "H30-57": "個人情報保護法2条2項にいう「個人識別符号」である",
    # ── choice型で肢が名詞句・語句のみの問題 ──
    "R1-38":  "公開会社において、{}、権利行使の6ヵ月（定款による短縮可）前から引き"
              "続き株式を有する株主のみが権利を行使できると会社法は定めている。",
    "R6-53":  "住民基本台帳法に明示されている住民票の記載事項である",
    "H21-7":  "日本国憲法の定めによると、両院協議会を必ずしも開かなくてもよいとされている",
    "H23-57": "語群「{}」には、カギ括弧内の語句と密接に関連しているとはいえない語句が含まれている。",
    "H24-2":  "「{}」という条文は、正しい法律の条文においては「みなす」ではなく"
              "「推定する」の文言が用いられている。",
    "H25-38": "{}、その決議は、株主総会の決議無効確認の訴えにおいて無効原因となる。",
    "H25-56": "{}、個人情報保護法上、あらかじめ本人の同意を得る必要がある。",
    "H26-40": "会社法の規定に照らし、定款の定めを必要としない",
    "H26-57": "個人情報取扱事業者の義務規定の適用除外として個人情報保護法に定められていない",
    "H27-4":  "この文章にいう「生存権的基本権」の本来的な特徴を備えているとはいえない",
    "H27-40": "会社法の規定に照らし、登記を必要とする事項である",
    "H28-55": "IoT（Internet of Things）とは、{}である。",
    "H29-30": "ＢおよびＡの占有が「{}」であるとき、Ａは、自己の占有または自己の占有に"
              "Ｂの占有を併せた占有を主張しても、甲不動産を時効取得できない。",
    "H29-51": "「{}」を比較すると、Ａの方がＢよりも大きな値となる。",
    "H30-6":  "この提案（公職選挙法改正案）による抵触が問題となり得ない選挙原則である",
}

# 正誤が逆転するネガティブ問のパターン
NEGATIVE_PAT = re.compile(
    r'誤り|妥当でない|正しくない|誤っている|不適切|間違い'
    r'|読み取れない'       # 「この文章から読み取れない内容」（H24-6）
    r'|矛盾するもの'       # 「判決の内容と明らかに矛盾するもの」（H24-19）
    r'|趣旨と異なる'       # 「判決の趣旨と異なるもの」（H25-7）
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

    # 並べ替え問題（年代順・文章の論理的順序）はO×に変換できない
    if re.search(r"年代順|並び順|論理的な順序|順に並べ", qt):
        return True, "並べ替え"

    # 「異質な1枚」を探す問題（H26-4: 判例のカードをばらまいて紛れ込んだ失敗カードを探す）
    # → 各肢の正誤は「文として正しいか」ではなく「他の肢と論理的に整合するか」を問うため、
    #   O×（文単体の真偽）に変換すると全肢の正誤が意味的に反転してしまう
    if re.search(r"捨てるはずだった失敗カード|紛れ込んだ", qt):
        return True, "異質カード探し（O×変換不可）"

    return False, ""


def is_valid_limb_text(text: str) -> bool:
    """肢テキストがO×文として使えるか（語句組合せ・数量答え・法改正削除肢を除外）"""
    t = text or ""
    return not (COMBO_ANS_PAT.search(t) or COUNT_ANS_PAT.match(t.strip())
                or JUNK_LIMB_PAT.search(t))


def extract_year_num(q_id: str):
    m = re.match(r"^([A-Za-z][A-Za-z0-9]*)-(\d+)", q_id)
    if m:
        return m.group(1), int(m.group(2))
    return "", 0


def _limb_needs_context(text: str) -> bool:
    """肢テキスト単体では判断できない参照語（先行詞なしの本件・同法・同条）を含むか"""
    # 「本件〜」は問題文で定義された事案を指す
    if "本件" in text:
        return True
    # 「同法」「同条」の先行詞（〜法・〜条）が肢内に存在しない場合
    for ref, ante_pat in (("同法", r"[一-龥ァ-ヴーa-zA-Z０-９0-9]+法"),
                          ("同条", r"[0-9０-９一二三四五六七八九十]+条")):
        pos = text.find(ref)
        if pos >= 0 and not re.search(ante_pat, text[:pos]):
            return True
    return False


def get_scenario_text(q: dict) -> str:
    """事例問題の場合に scenarioText（問題の前提状況）を返す。不要なら空文字。"""
    qt = q.get("questionText", "")
    limbs = q.get("limbs", [])

    # 強制付与リスト
    if q.get("id") in SCENARIO_FORCE_IDS:
        return qt

    # パターン4: combo_ox で全肢が名詞句（。で終わらない）の問題
    # 「〇〇の組合せ」問題の選択肢が固有名詞・短語句だけのケース（R5-30、R1-56等）
    if q.get("answerType") == "combo_ox":
        if limbs and all(not l.get("text", "").strip().endswith("。") for l in limbs):
            return qt

    # パターン1: 「本件処分」のようなエイリアスを定義し、肢でそのエイリアスを使用
    alias_match = ALIAS_DEF_PAT.search(qt)
    if alias_match:
        alias = alias_match.group(1)
        if any(alias in l.get("text", "") for l in limbs):
            return qt

    # パターン2: 問題文と肢の両方に当事者記号（A・B・甲など）が登場
    if SCENARIO_PAT.search(qt):
        if any(SCENARIO_PAT.search(l.get("text", "")) for l in limbs):
            return qt

    # パターン3: 「この判決」「この文章の趣旨」等、問題文本体を参照して肢を判断する問題
    if REF_QT_PAT.search(qt[:300]):
        return qt

    # パターン5: 肢が先行詞のない参照語（本件・同法・同条）を含む
    if any(_limb_needs_context(l.get("text", "")) for l in limbs):
        return qt

    return ""


# NEGATIVE_PATにマッチしない言い回しでcorrectが「選択された答え（＝異質な1肢）」を
# 意味しているChoice型問題（cache/html再検証で発見）。
# H24-2:「『みなす』ではなく『推定する』が使われるべきものが一つだけある。それはどれか」
#        → correct=Trueは「誤用されている1肢（異質な答え）」を指し、文自体の正誤ではない。
INVERSION_FORCE_IDS = {"H24-2"}


def needs_correct_inversion(q: dict) -> bool:
    """choiceで1肢だけcorrect=Trueかつネガティブ問の場合、O×変換時にcorrectを反転する必要がある。
    この場合 correct=True は「正解選択肢（=誤り肢）」を意味するため。"""
    if q.get("answerType") != "choice":
        return False
    if q.get("id") in INVERSION_FORCE_IDS:
        return True
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

            noun_pred = NOUN_PHRASE_PREDICATES.get(q_id, "")
            if noun_pred:
                if "{}" in noun_pred:
                    limb_text = noun_pred.format(limb_text)
                else:
                    limb_text = f"{limb_text}は、{noun_pred}。"

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
