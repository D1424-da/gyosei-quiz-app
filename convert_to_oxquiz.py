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
from quiz_utils import ALL_QUESTIONS_JSON, OXQUIZ_OUTPUT_JSON, load_json, save_json

DEFAULT_INPUT  = str(ALL_QUESTIONS_JSON)
DEFAULT_OUTPUT = str(OXQUIZ_OUTPUT_JSON)

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

# 問題文をそのまま scenarioText にする問題（肢の判断に問題文の列挙部分が必要なもの）
SCENARIO_FORCE_IDS = {
    "H30-6",   # 政党Xの公選法改正提案（ア～エ）が問題文にしかない
}

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


# 肢の列挙（ア．イ．… / 1. 2. …）の始まり
_KATA_LINE_PAT = re.compile(r"^[アイウエオカキクケコ][\s　．.、:：]")
_NUM_LINE_PAT = re.compile(r"^[1-5１-５][\s　．.]")

# 「次の記述のうち…どれか」のような五択の設問フレーム。
# 1問1答では意味をなさない（1肢しか出さないのに「どれか」と問うことになる）ため落とす。
_ASK_PAT = re.compile(r"どれか|選べ|選びなさい|いくつあるか|組合せ|正しいものは|妥当なものは|誤っているものは")
_ASK_REF_PAT = re.compile(r"次の|下記の|以下の|記述のうち|うち")
# 「（出題ミスで複数正解）」のような注記だけの文
_NOTE_ONLY_PAT = re.compile(r"^[（(].{0,40}[）)]。?$")


def _lead_before_limbs(text: str) -> str:
    """肢の列挙が始まる手前までを返す（肢本文の二重表示を防ぐ）。"""
    lines = (text or "").split("\n")
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if _KATA_LINE_PAT.match(stripped) or _NUM_LINE_PAT.match(stripped):
            if i > 0:
                return "\n".join(lines[:i]).rstrip()
            break
    m = re.search(r"[アイウエオカキクケコ][．.]", text or "")
    return (text or "")[:m.start()].rstrip() if m else (text or "").rstrip()


def _split_sentences(text: str) -> list:
    """。で文分割する。括弧・鉤括弧の内側の。では切らない。"""
    out, buf, depth = [], [], 0
    opening, closing = "（(「『【〔[", "）)」』】〕]"
    for ch in text:
        buf.append(ch)
        if ch in opening:
            depth += 1
        elif ch in closing:
            depth = max(0, depth - 1)
        elif ch == "。" and depth == 0:
            out.append("".join(buf).strip())
            buf = []
    tail = "".join(buf).strip()
    if tail:
        out.append(tail)
    return [s for s in out if s.strip("。 　\n")]


def clean_lead_text(question_text: str) -> str:
    """問題文から、1問1答で意味を持つ前提状況（リード文）だけを取り出す。

    元の問題文は「A所有の甲土地と…が存在している。この場合における次のア～オの
    記述のうち…組合せはどれか。」のような形をしており、後半の設問フレームは
    1肢だけを出題する本アプリでは誤解のもとになるため取り除く。
    残るのが設問フレームだけ（例:「家族・婚姻に関する次の記述のうち…どれか。」）なら
    空文字を返す（テーマはカテゴリバッジで示されるため）。
    """
    sentences = _split_sentences(_lead_before_limbs(question_text))
    kept = []
    for s in sentences:
        if _NOTE_ONLY_PAT.match(s):
            continue
        # 設問フレーム文を落とす。「次の記述のうち…」型に加え、
        # 「この判決の趣旨と異なるものはどれか。」のような短い指示文も対象にする。
        # 事案説明と設問が1文に融合している長文は、落とすと前提が失われるため残す。
        if _ASK_PAT.search(s) and (_ASK_REF_PAT.search(s) or len(s) <= 40):
            continue
        kept.append(s)
    lead = "\n".join(kept).strip()
    return lead if len(lead) >= 15 else ""


def get_scenario_text(q: dict) -> str:
    """scenarioText（問題の前提状況＝リード文）を返す。前提状況がなければ空文字。

    前提状況が書かれている問題では、肢単体で判断できるかどうかに関わらず常に付ける。
    以前は「肢が本件・同法などの参照語を含むか」等で付けるかどうかを切り替えていたが、
    リード文が付いたり付かなかったりして出題形式が不揃いに見えるため、判定をやめた。
    """
    # 肢の判断に問題文の列挙部分そのものが必要な問題は、原文をそのまま渡す。
    if q.get("id") in SCENARIO_FORCE_IDS:
        return q.get("questionText", "")

    return clean_lead_text(q.get("questionText", ""))


# ── 空欄補充問題のO×化 ────────────────────────────────────────
# 「次の文章の空欄［ア］～［エ］に当てはまる語句の組合せとして正しいものはどれか」型。
# 各肢が「ア：語句 イ：語句 …」という組合せになっており、そのままでは1問1答にならない。
# 正解の組合せから「空欄→正しい語句」を取り出し、他の肢に現れる語句を誤答として使って
# 「空欄［ア］に入る語句は「◯◯」である。」という単独のO×問題に分解する。

BLANK_LABELS = "アイウエオカキクケコ" + "ⅠⅡⅢⅣⅤⅥⅦ" + "ABCDEＡＢＣＤＥ"
_BLANK_ITEM_PAT = re.compile(r"[（(]?([" + BLANK_LABELS + r"])[）)]?\s*[：:]\s*")
# 語群（ア～コ）への間接参照（「Ⅰ：ア Ⅱ：ウ」）は、語群自体が問題文側にあるため対象外
_GUNGUN_REF_PAT = re.compile(r"^[アイウエオカキクケコ]$")


def parse_blank_combo(text: str) -> dict:
    """「ア：語句 イ：語句」形式の肢を {ラベル: 語句} に分解する。"""
    parts = _BLANK_ITEM_PAT.split(text or "")
    combo = {}
    for i in range(1, len(parts) - 1, 2):
        word = parts[i + 1].strip().rstrip("、,").strip()
        if word:
            combo[parts[i]] = word
    return combo


def convert_blank_fill(q: dict) -> list:
    """空欄補充問題を、空欄ごと・候補語ごとのO×問題に分解する。変換できなければ空リスト。"""
    limbs = q.get("limbs", [])
    combos = [(l, parse_blank_combo(l.get("text", ""))) for l in limbs]
    correct_combo = next((c for l, c in combos if l.get("correct")), None)

    # 単一空欄（「空欄［ ］に当てはまる語句として妥当なものはどれか」）は
    # 肢そのものが候補語なので、ラベルなしの1空欄として扱う。
    if not correct_combo and not any(c for _, c in combos):
        correct_limb = next((l for l in limbs if l.get("correct")), None)
        words = [l.get("text", "").strip() for l in limbs if l.get("text", "").strip()]
        # 肢が文章の場合（「〜すべきでないものはどれか」型）は語句補充ではないので除外
        if not correct_limb or not words or max(len(w) for w in words) > 25:
            return []
        combos = [(l, {"": l.get("text", "").strip()}) for l in limbs]
        correct_combo = {"": correct_limb.get("text", "").strip()}

    if not correct_combo:
        return []
    if any(_GUNGUN_REF_PAT.match(w) for w in correct_combo.values()):
        return []

    candidates = {}
    for _, combo in combos:
        for label, word in combo.items():
            candidates.setdefault(label, [])
            if word not in candidates[label]:
                candidates[label].append(word)
    if not candidates:
        return []

    q_id = q["id"]
    year, qnum = extract_year_num(q_id)
    scenario = get_scenario_text(q)
    # 空欄補充は本文がなければ答えようがない（本文が未スクレイプの問題がある）
    if not scenario:
        return []

    out = []
    for label, words in candidates.items():
        if label not in correct_combo:
            continue
        for n, word in enumerate(words):
            where = f"空欄［{label}］" if label else "空欄"
            ox_q = {
                "id": f"{q_id}-blank{label}{n}",
                "parentId": q_id,
                "year": year,
                "questionNumber": qnum,
                "subject": q.get("subject", "行政書士"),
                "category": q.get("category", ""),
                "source": q.get("source", ""),
                "answerType": "ox",
                "limbs": [
                    {
                        "id": f"{q_id}-b{label}{n}-ox",
                        "text": f"{where}に入る語句は「{word}」である。",
                        "correct": word == correct_combo[label],
                        "explanation": f"{where}に入るのは「{correct_combo[label]}」です。",
                    }
                ],
                "questionUrl": q.get("questionUrl", ""),
            }
            if scenario:
                ox_q["scenarioText"] = scenario
            out.append(ox_q)
    return out


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
    questions = load_json(input_path)

    ox_questions = []
    skip_counts = {}
    invalid_limb_count = 0
    scenario_count = 0
    inversion_count = 0
    blank_fill_questions = 0
    blank_fill_items = 0

    for q in questions:
        skip, reason = should_skip_question(q)
        if skip:
            # 空欄補充は組合せを分解すれば1問1答にできるので、スキップせず変換を試みる
            if reason == "空欄補充":
                generated = convert_blank_fill(q)
                if generated:
                    ox_questions.extend(generated)
                    blank_fill_questions += 1
                    blank_fill_items += len(generated)
                    continue
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
                        "explanation": (limb.get("explanation") or "").strip(),
                    }
                ],
                "questionUrl": q.get("questionUrl", ""),
            }
            if scenario_text:
                ox_q["scenarioText"] = scenario_text
            ox_questions.append(ox_q)

    save_json(output_path, ox_questions)

    print(f"変換完了: {len(ox_questions)} 問 → {output_path}")
    print("スキップ内訳:")
    for reason, count in skip_counts.items():
        print(f"  {reason}: {count} 問")
    print(f"  語句組合せ肢（除外）: {invalid_limb_count} 件")
    print(f"空欄補充から生成: {blank_fill_questions} 問 → {blank_fill_items} 問（1問1答）")
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
