#!/usr/bin/env python3
"""
audit_cache_html.py
--------------------
cache/html/ 配下の gyosyo.info スクレイプ済みHTMLを「正解ソース」として再パースし、
output/gyosyo_all_questions.json の内容と突き合わせて矛盾を検出する。

検出する矛盾:
  1. LIMB_COUNT_MISMATCH : 大問が期待する肢の数とJSON上の肢数が一致しない
                            （＝大問がその肢を判断するのに必要な設定・肢を欠いている）
  2. LIMB_TEXT_MISMATCH  : 肢テキストがHTMLとJSONで大きく異なる
  3. CORRECT_MISMATCH    : ○×（correct）がHTMLとJSONで異なる
  4. ANSWER_UNRESOLVED   : 【答え】が組合せ選択肢のどれとも一致せず、正誤を機械的に確定できない

正誤の判定方法（重要）:
  combo_ox型（ア・イ・ウ…の記述から正しい組合せを選ぶ問題）は、各肢の解説文
  （「イ・・・正しい」等）を直接パースするのではなく、
    ①〈ol><li>の組合せ選択肢一覧（例: "ア・イ", "ア・オ", ...）
    ②【答え】：N （N番目の組合せが正解）
  の2つから「どのカナが正解の組合せに含まれるか」を機械的に算出する。
  理由: 解説文には「使用貸借に当てはまるが、賃貸借に当てはまらない」のような
  非二値的な言い回しがあり、正誤語（正しい/誤り等）の単純な文字列一致では
  誤判定するケースがあるため（例: H30-32）。組合せからの逆算なら曖昧さがない。

  choice型（1～5の記述から1つ選ぶ問題）は、各肢の解説見出し
  （「１・・・正しい」「２・・・誤り」等）から直接、二値判定を抽出する
  （こちらは元々二値の言い回ししか使われないため、素直な文字列一致で安全）。

使い方:
  python3 audit_cache_html.py                     # 全問監査してレポート出力（書き込みなし）
  python3 audit_cache_html.py --ids H23-20 H30-32  # 特定の問題IDのみ
  python3 audit_cache_html.py --category 民法      # カテゴリ絞り込み
  python3 audit_cache_html.py --apply-safe         # 「安全」と判断した修正のみ自動適用
                                                     #（肢数一致・combo_ox の correct 不一致のみ。
                                                     #   肢の欠落・choice型の不一致は目視確認用に
                                                     #   レポートするだけで自動適用しない）

出力:
  output/cache_audit_report.json  検出した矛盾の一覧（常に出力）
  --apply-safe 指定時のみ output/gyosyo_all_questions.json を書き換える
"""

import json
import re
import sys
import argparse
import unicodedata
import difflib
from html import unescape
from pathlib import Path

from convert_to_oxquiz import get_scenario_text

DATA_DIR       = Path(__file__).parent / "output"
CACHE_HTML_DIR = Path(__file__).parent / "cache" / "html"
SRC_FILE       = DATA_DIR / "gyosyo_all_questions.json"
REPORT_FILE    = DATA_DIR / "cache_audit_report.json"

KATA = "アイウエオカキクケコ"

_CORRECT_WORDS  = ["正しい", "妥当", "適切", "正解"]
_NEGATIVE_WORDS = ["でない", "ではない", "誤り", "誤っ", "まちがい", "不適切", "でなく", "誤っている"]

# 「組合せ」の中身が"誤っている/妥当でない肢"を指す問題（要 correct 反転）
COMBO_NEGATIVE_PAT = re.compile(r"妥当でない|誤っている|正しくない|不適切な")


# ── HTMLパース基本ユーティリティ ──────────────────────────────

def strip_tags(fragment: str) -> str:
    text = re.sub(r"<[^>]+>", "", fragment)
    text = unescape(text)
    text = re.sub(r"[ \t　]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text)
    return text.strip()


def find_balanced_div(html: str, open_tag_pattern: str, start: int = 0):
    """
    open_tag_pattern にマッチする <div ...> を探し、対応する閉じタグまでの
    (content_start, content_end) を返す。深さカウントでネストに対応。
    見つからなければ None。
    """
    m = re.compile(open_tag_pattern).search(html, start)
    if not m:
        return None
    depth = 1
    tag_re = re.compile(r"<div\b[^>]*>|</div>", re.IGNORECASE)
    for tm in tag_re.finditer(html, m.end()):
        if tm.group().lower().startswith("<div"):
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return m.end(), tm.start()
    return None


def zenkaku_to_num(s: str) -> int | None:
    """全角/漢数字混じりの番号表記から整数を取り出す（最初の1つ）。"""
    norm = unicodedata.normalize("NFKC", s)
    m = re.search(r"\d+", norm)
    return int(m.group()) if m else None


# ── ページ全体のパース ────────────────────────────────────────

class ParsedPage:
    def __init__(self):
        self.stem = ""             # 大問（リード文）
        self.kata_limbs = {}       # combo_ox: {'ア': text, ...}
        self.numbered_limbs = {}   # choice: {1: text, ...}
        self.combo_choices = []    # combo_ox: ["ア・イ", "ア・オ", ...] (1-indexed by position)
        self.answer_nums = []      # 【答え】で示された番号（複数選択の場合は複数）
        self.verdicts = {}         # {'ア' or 1: True/False}  waku-q/waku-a から抽出した明示的正誤
        self.parse_error = ""


def parse_page(html: str) -> ParsedPage:
    page = ParsedPage()

    sec = find_balanced_div(html, r'<section\s+class="post-content"[^>]*>')
    if not sec:
        page.parse_error = "post-content セクションが見つからない"
        return page
    html = html[sec[0]:sec[1]]

    toi = find_balanced_div(html, r'<div\s+id="toi">')
    if not toi:
        page.parse_error = "#toi が見つからない"
        return page
    toi_content = html[toi[0]:toi[1]]

    waku1 = find_balanced_div(toi_content, r'<div\s+class="waku-1">')

    if waku1:
        stem_html = toi_content[:waku1[0]]
        # waku-1 の開始タグ分を遡ってpreambleに含めないよう調整
        stem_html = re.sub(r'<div\s+class="waku-1">\s*$', "", stem_html)
        page.stem = strip_tags(stem_html)

        waku1_content = toi_content[waku1[0]:waku1[1]]
        kata_text = strip_tags(waku1_content)
        matches = list(re.finditer(r"([" + KATA + r"])[．.、]", kata_text))
        for i, m in enumerate(matches):
            k = m.group(1)
            start = m.end()
            end = matches[i + 1].start() if i + 1 < len(matches) else len(kata_text)
            page.kata_limbs[k] = kata_text[start:end].strip()

        rest = toi_content[waku1[1]:]
        ol_m = re.search(r"<ol>(.*?)</ol>", rest, re.DOTALL)
        if ol_m:
            items = re.findall(r"<li>(.*?)</li>", ol_m.group(1), re.DOTALL)
            page.combo_choices = [strip_tags(x) for x in items]
    else:
        ol_m = re.search(r"<ol>(.*?)</ol>", toi_content, re.DOTALL)
        if ol_m:
            stem_html = toi_content[:ol_m.start()]
            page.stem = strip_tags(stem_html)
            items = re.findall(r"<li>(.*?)</li>", ol_m.group(1), re.DOTALL)
            for i, item in enumerate(items):
                page.numbered_limbs[i + 1] = strip_tags(item)
        else:
            page.stem = strip_tags(toi_content)

    # 「#kaitou」の div ネストが実際のページで壊れている（早期に </div> で閉じてしまう）
    # ケースがあるため、balanced-div ではなく開始タグの直後からセクション末尾までを対象にする
    kaitou_m = re.search(r'<div\s+id="kaitou">', html)
    if not kaitou_m:
        page.parse_error = (page.parse_error + "; " if page.parse_error else "") + "#kaitou が見つからない"
        return page
    kaitou_content = html[kaitou_m.end():]

    ans_m = re.search(r"【答え】\s*[：:]\s*([^<\n]+)", kaitou_content)
    if ans_m:
        raw = ans_m.group(1)
        nums = re.findall(r"[0-9０-９]+", unicodedata.normalize("NFKC", raw))
        if nums:
            page.answer_nums = [int(n) for n in nums]
        else:
            katas_in_ans = [c for c in raw if c in KATA]
            page.answer_nums = katas_in_ans  # combo_ox で「ア・イ」形式の直接記載の場合

    # waku-q/waku-a ペアから各肢の明示的正誤を抽出（choice型の一次情報源）
    for m in re.finditer(r'<div\s+class="waku-q">', kaitou_content):
        qa = find_balanced_div(kaitou_content, r'<div\s+class="waku-q">', m.start())
        if not qa:
            continue
        q_end = qa[1]
        wa_m = re.match(r'\s*</div>\s*<div\s+class="waku-a">', kaitou_content[q_end:q_end + 80])
        if not wa_m:
            continue
        wa = find_balanced_div(kaitou_content, r'<div\s+class="waku-a">', q_end)
        if not wa:
            continue
        a_text = strip_tags(kaitou_content[wa[0]:wa[1]])
        head_m = re.match(r"^([" + KATA + r"0-9０-９]+)(?:[・･]{1,3}|[．.])(.{0,20})", a_text)
        if not head_m:
            continue
        label, verdict_word = head_m.group(1), head_m.group(2)
        key = label if label in KATA else zenkaku_to_num(label)
        if key is None:
            continue
        has_c = any(w in verdict_word for w in _CORRECT_WORDS)
        has_n = any(w in verdict_word for w in _NEGATIVE_WORDS)
        if has_c or has_n:
            page.verdicts[key] = has_c and not has_n

    return page


# ── 正解の確定ロジック ────────────────────────────────────────

def resolve_combo_correctness(page: ParsedPage, question_text: str = ""):
    """
    combo_ox型: 組合せ選択肢一覧 + 答え番号 から各カナの correct を機械的に算出。
    「妥当でないものの組合せ」等ネガティブ枠組みの場合は、選ばれた組合せが
    「誤り肢の集合」を意味するため、correct の意味を反転する
    （correct=True は常に「肢の文が客観的に正しい」ことを意味する規約に統一）。
    戻り値: ({kana: bool}, note)
    """
    if not page.combo_choices or not page.answer_nums:
        return None, "組合せ選択肢または答え番号が取得できない"

    ans = page.answer_nums[0]
    if isinstance(ans, int):
        if ans < 1 or ans > len(page.combo_choices):
            return None, f"答え番号{ans}が選択肢数{len(page.combo_choices)}の範囲外"
        correct_combo_text = page.combo_choices[ans - 1]
    else:
        return None, "答えがカナ直接記載形式で選択肢番号と対応付け不可"

    selected_katas = set(re.findall(r"[" + KATA + r"]", correct_combo_text))
    if not selected_katas:
        return None, f"正解選択肢テキストからカナを抽出できない: {correct_combo_text!r}"

    is_negative = bool(COMBO_NEGATIVE_PAT.search(question_text))
    result = {k: ((k in selected_katas) != is_negative) for k in page.kata_limbs}
    note = f"答え{ans}番目の組合せ「{correct_combo_text}」から算出"
    if is_negative:
        note += "（ネガティブ枠組みのため反転）"
    return result, note


def resolve_choice_correctness(page: ParsedPage):
    """
    choice型: waku-q/waku-a の明示的正誤（page.verdicts）をそのまま採用。
    フォールバックとして答え番号のみ True にする単純化はしない
    （複数選択「すべて選べ」形式があるため、verdicts が唯一の信頼できる情報源）。
    """
    if not page.verdicts:
        return None, "各肢の正誤見出しが抽出できない"
    return dict(page.verdicts), "waku-a見出しの正誤語から抽出"


# ── JSONとの突き合わせ ────────────────────────────────────────

def text_similarity(a: str, b: str) -> float:
    a = re.sub(r"\s+", "", a)
    b = re.sub(r"\s+", "", b)
    if not a or not b:
        return 0.0
    return difflib.SequenceMatcher(None, a, b).ratio()


def audit_question(q: dict) -> dict:
    findings = {
        "id": q["id"],
        "answerType": q.get("answerType"),
        "issues": [],
    }

    url = q.get("questionUrl", "")
    if not url:
        return findings

    import hashlib
    cache_path = CACHE_HTML_DIR / f"{hashlib.sha256(url.encode()).hexdigest()}.html"
    if not cache_path.exists():
        return findings

    html = cache_path.read_text(encoding="utf-8", errors="replace")
    page = parse_page(html)
    if page.parse_error:
        findings["issues"].append({
            "type": "PARSE_ERROR",
            "detail": page.parse_error,
        })
        return findings

    json_limbs = q.get("limbs", [])
    at = q.get("answerType")

    if at == "combo_ox" and page.kata_limbs:
        katas_ordered = list(page.kata_limbs.keys())
        json_texts = [l.get("text", "") for l in json_limbs]

        # カナごとのHTML肢テキストとJSON肢テキストを類似度で最適対応付けする
        # （肢が1つ欠けているだけで単純な位置対応は全てズレるため）
        kana_to_json_idx = {}
        used_json_idx = set()
        # 類似度が高い順に貪欲マッチング
        pairs = []
        for kana in katas_ordered:
            for j, jt in enumerate(json_texts):
                pairs.append((text_similarity(page.kata_limbs[kana], jt), kana, j))
        pairs.sort(reverse=True)
        for sim, kana, j in pairs:
            if sim < 0.5:
                break
            if kana in kana_to_json_idx or j in used_json_idx:
                continue
            kana_to_json_idx[kana] = j
            used_json_idx.add(j)

        expected_n = len(page.kata_limbs)
        actual_n = len(json_limbs)
        if expected_n != actual_n:
            missing_katas = [k for k in katas_ordered if k not in kana_to_json_idx]
            findings["issues"].append({
                "type": "LIMB_COUNT_MISMATCH",
                "expected": expected_n,
                "actual": actual_n,
                "missing_from_json": [
                    {"kana": k, "text": page.kata_limbs[k]} for k in missing_katas
                ],
            })

        ground_truth, note = resolve_combo_correctness(page, q.get("questionText", ""))
        if ground_truth is None:
            findings["issues"].append({"type": "ANSWER_UNRESOLVED", "detail": note})
        else:
            findings["ground_truth_by_kana"] = ground_truth
            unmatched_json_idx = [j for j in range(len(json_limbs)) if j not in used_json_idx]
            for j in unmatched_json_idx:
                findings["issues"].append({
                    "type": "LIMB_TEXT_MISMATCH",
                    "limb_index": j,
                    "kana": None,
                    "json_text": json_texts[j][:80],
                    "html_text": "(対応するHTML肢が見つからない)",
                    "similarity": 0.0,
                })

            for kana, j in kana_to_json_idx.items():
                expected_correct = ground_truth.get(kana)
                actual_correct = bool(json_limbs[j].get("correct", False))
                if expected_correct is not None and expected_correct != actual_correct:
                    findings["issues"].append({
                        "type": "CORRECT_MISMATCH",
                        "limb_index": j,
                        "kana": kana,
                        "json_correct": actual_correct,
                        "html_correct": expected_correct,
                        "note": note,
                        "limb_text": json_texts[j][:80],
                    })

    elif at == "choice" and page.numbered_limbs:
        expected_n = len(page.numbered_limbs)
        actual_n = len(json_limbs)
        if expected_n != actual_n:
            findings["issues"].append({
                "type": "LIMB_COUNT_MISMATCH",
                "expected": expected_n,
                "actual": actual_n,
            })

        ground_truth, note = resolve_choice_correctness(page)
        if ground_truth is None:
            findings["issues"].append({"type": "ANSWER_UNRESOLVED", "detail": note})
        else:
            for i, limb in enumerate(json_limbs):
                num = i + 1
                html_text = page.numbered_limbs.get(num, "")
                json_text = limb.get("text", "")
                if not html_text:
                    continue
                sim = text_similarity(html_text, json_text)
                if sim < 0.5:
                    findings["issues"].append({
                        "type": "LIMB_TEXT_MISMATCH",
                        "limb_index": i,
                        "json_text": json_text[:80],
                        "html_text": html_text[:80],
                        "similarity": round(sim, 2),
                    })
                    continue

                expected_correct = ground_truth.get(num)
                actual_correct = bool(limb.get("correct", False))
                if expected_correct is not None and expected_correct != actual_correct:
                    findings["issues"].append({
                        "type": "CORRECT_MISMATCH",
                        "limb_index": i,
                        "json_correct": actual_correct,
                        "html_correct": expected_correct,
                        "note": note,
                        "limb_text": json_text[:80],
                    })

    # 大問（リード文）の情報が肢の理解に必要かどうかのチェック。
    # convert_to_oxquiz.py の get_scenario_text() を実際に呼び出して判定する
    # （※ 生の gyosyo_all_questions.json 自体には scenarioText フィールドは存在しない。
    #   それは変換時に convert_to_oxquiz.py が動的に生成するものなので、
    #   ここで独自に緩い判定基準を再実装すると変換ロジックとズレて誤検出になる）
    if page.stem and json_limbs:
        stem_has_context_markers = bool(re.search(r"以下[「『].{1,10}[」』]という|本件|[AＡBＢ][はがをにの]", page.stem))
        limbs_reference_stem = any(
            re.search(r"本件", l.get("text", "")) for l in json_limbs
        )
        if stem_has_context_markers and limbs_reference_stem and not get_scenario_text(q):
            findings["issues"].append({
                "type": "SCENARIO_TEXT_MISSING",
                "stem": page.stem[:150],
            })

    return findings


# ── 「安全な」自動適用 ────────────────────────────────────────

def apply_safe_fixes(src: list, reports: list) -> int:
    """
    以下のみ自動適用する（それ以外は目視確認に回す）:
      - combo_ox の CORRECT_MISMATCH（組合せから機械的に算出した正解なので信頼度が高い）
      - combo_ox の LIMB_COUNT_MISMATCH で missing_from_json が空でない場合、
        欠落肢をHTMLから復元して追加（末尾に追加、correctは組合せから算出）
    choice型の不一致・LIMB_TEXT_MISMATCH・SCENARIO_TEXT_MISSING は自動適用しない。
    """
    by_id = {q["id"]: q for q in src}
    applied = 0

    for r in reports:
        q = by_id.get(r["id"])
        if not q or r["answerType"] != "combo_ox":
            continue

        for issue in r["issues"]:
            if issue["type"] == "CORRECT_MISMATCH":
                idx = issue["limb_index"]
                if 0 <= idx < len(q["limbs"]):
                    q["limbs"][idx]["correct"] = issue["html_correct"]
                    applied += 1

            elif issue["type"] == "LIMB_COUNT_MISMATCH" and issue.get("missing_from_json"):
                # 欠落肢は末尾に追加するのみ（カナ順の挿入位置までは特定しない = 目視で並び替え推奨）
                gt = r.get("ground_truth_by_kana", {})
                for miss in issue["missing_from_json"]:
                    new_id = f"{q['id']}-l{len(q['limbs'])}"
                    q["limbs"].append({
                        "id": new_id,
                        "text": miss["text"],
                        "correct": bool(gt.get(miss["kana"], False)),
                        "explanation": "",
                    })
                    applied += 1

    return applied


# ── メイン ────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="cache/html を正解ソースとしてO×データを監査する")
    parser.add_argument("--ids", nargs="+", help="対象を特定の問題IDに絞る")
    parser.add_argument("--category", help="カテゴリで絞り込み")
    parser.add_argument("--apply-safe", action="store_true",
                         help="安全と判断した修正のみ自動適用してJSONを上書きする")
    args = parser.parse_args()

    with open(SRC_FILE, encoding="utf-8-sig") as f:
        src = json.load(f)

    targets = src
    if args.ids:
        idset = set(args.ids)
        targets = [q for q in targets if q["id"] in idset]
    if args.category:
        targets = [q for q in targets if q.get("category") == args.category]

    reports = []
    counts = {
        "LIMB_COUNT_MISMATCH": 0,
        "LIMB_TEXT_MISMATCH": 0,
        "CORRECT_MISMATCH": 0,
        "ANSWER_UNRESOLVED": 0,
        "SCENARIO_TEXT_MISSING": 0,
        "PARSE_ERROR": 0,
    }

    for q in targets:
        if q.get("answerType") not in ("combo_ox", "choice"):
            continue
        result = audit_question(q)
        if result["issues"]:
            reports.append(result)
            for issue in result["issues"]:
                counts[issue["type"]] = counts.get(issue["type"], 0) + 1

    with open(REPORT_FILE, "w", encoding="utf-8") as f:
        json.dump(reports, f, ensure_ascii=False, indent=2)

    print("=" * 64)
    print(f"監査対象: {len(targets)} 問（combo_ox / choice のみ）")
    print(f"矛盾検出: {len(reports)} 問")
    for k, v in counts.items():
        if v:
            print(f"  {k}: {v} 件")
    print(f"詳細レポート: {REPORT_FILE}")

    if args.apply_safe:
        applied = apply_safe_fixes(src, reports)
        with open(SRC_FILE, "w", encoding="utf-8") as f:
            json.dump(src, f, ensure_ascii=False, indent=2)
        print(f"\n✏️  安全な修正を適用: {applied} 件 → {SRC_FILE}")
        print("   ※ combo_ox の CORRECT_MISMATCH と欠落肢の復元のみ。")
        print("   ※ choice型の不一致・LIMB_TEXT_MISMATCH・SCENARIO_TEXT_MISSINGは")
        print("     目視確認の上、手動で対応してください。")
    else:
        print("\n(--apply-safe を付けなかったため、JSONへの書き込みは行っていません)")


if __name__ == "__main__":
    main()
