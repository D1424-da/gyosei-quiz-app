#!/usr/bin/env python3
"""
extract_explanations.py
-----------------------
cache/html/ のスクレイプ済みHTMLから、肢ごとの本物の解説を抽出して
output/gyosyo_all_questions.json の limbs[].explanation を埋める。

背景:
  スクレイパーが入れた explanation は「肢アの見出しテキスト」が全肢に複製された
  だけの無意味な値になっている（例: R1-2 の肢イ〜オ の解説がすべて肢アの本文）。
  一方 cache/html には <div class="waku-a"> 内に肢ごとの詳細な解説（条文引用つき）が
  そのまま残っているため、そこから抽出し直す。

抽出方法:
  audit_cache_html.py と同じ waku-q / waku-a のペア構造を辿り、waku-a の本文を
  その肢の解説として採用する。見出し（「ア・・・誤り」「1・・・正しい」）は
  アプリ側が正解を別途表示するため取り除く。

使い方:
  python3 extract_explanations.py --dry-run   # 書き込まずに件数だけ表示
  python3 extract_explanations.py             # gyosyo_all_questions.json を更新
"""

import argparse
import hashlib
import re
import unicodedata
from html import unescape

from quiz_utils import CACHE_HTML_DIR, ALL_QUESTIONS_JSON, load_json, save_json

KATA = "アイウエオカキクケコ"

# 解説冒頭の見出し「ア・・・誤り」「1・・・正しい」等を取り除くためのパターン
_HEAD_RE = re.compile(
    r"^([" + KATA + r"0-9０-９]+)(?:[・･]{1,3}|[．.])\s*"
    r"(?:正しい|正解|妥当(?:でない|ではない)?|適切(?:でない|ではない)?|"
    r"誤り|誤っている|誤っ\S{0,3}|まちがい|不適切)?\s*"
)


def strip_tags(fragment: str) -> str:
    text = re.sub(r"<[^>]+>", "\n", fragment)
    text = unescape(text)
    text = re.sub(r"[ \t　]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text)
    return text.strip()


def find_balanced_div(html: str, open_tag_pattern: str, start: int = 0):
    """open_tag_pattern の <div> に対応する閉じタグまでの (content_start, content_end)。"""
    m = re.compile(open_tag_pattern).search(html, start)
    if not m:
        return None
    depth = 1
    for tm in re.finditer(r"<div\b[^>]*>|</div>", html[m.end():], re.IGNORECASE):
        if tm.group().lower().startswith("<div"):
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return m.end(), m.end() + tm.start()
    return None


def zenkaku_to_num(s: str):
    m = re.search(r"\d+", unicodedata.normalize("NFKC", s))
    return int(m.group()) if m else None


def cache_path_for(url: str):
    if not url:
        return None
    return CACHE_HTML_DIR / f"{hashlib.sha256(url.encode()).hexdigest()}.html"


def extract_explanations(html: str) -> dict:
    """{'ア': 解説, 1: 解説, ...} を返す。"""
    out = {}
    kaitou_m = re.search(r'<div\s+id="kaitou">', html)
    if not kaitou_m:
        return out
    kaitou = html[kaitou_m.end():]

    for m in re.finditer(r'<div\s+class="waku-q">', kaitou):
        qa = find_balanced_div(kaitou, r'<div\s+class="waku-q">', m.start())
        if not qa:
            continue
        # waku-q の直後に waku-a が続くペアだけを対象にする
        if not re.match(r'\s*</div>\s*<div\s+class="waku-a">', kaitou[qa[1]:qa[1] + 80]):
            continue
        wa = find_balanced_div(kaitou, r'<div\s+class="waku-a">', qa[1])
        if not wa:
            continue

        body = strip_tags(kaitou[wa[0]:wa[1]])
        head_m = re.match(r"^([" + KATA + r"0-9０-９]+)(?:[・･]{1,3}|[．.])", body)
        if not head_m:
            continue
        label = head_m.group(1)
        key = label if label in KATA else zenkaku_to_num(label)
        if key is None:
            continue

        body = _HEAD_RE.sub("", body, count=1).strip()
        # 個別指導などの宣伝行が末尾に混ざるため落とす
        body = re.sub(r"\n?[^\n]*個別指導[^\n]*$", "", body).strip()
        if body:
            out[key] = body
    return out


def limb_key(index: int, answer_type: str):
    """肢インデックスを解説キー（カナ or 数字）に変換する。"""
    if answer_type == "combo_ox":
        return KATA[index] if index < len(KATA) else None
    return index + 1


def main():
    ap = argparse.ArgumentParser(description="cache/html から肢ごとの解説を抽出して埋める")
    ap.add_argument("--input", default=str(ALL_QUESTIONS_JSON))
    ap.add_argument("--dry-run", action="store_true", help="書き込まずに件数だけ表示")
    args = ap.parse_args()

    questions = load_json(args.input)

    filled = replaced = no_cache = no_match = 0
    for q in questions:
        path = cache_path_for(q.get("questionUrl", ""))
        if not path or not path.exists():
            no_cache += 1
            continue
        exps = extract_explanations(path.read_text(encoding="utf-8", errors="replace"))
        if not exps:
            no_match += 1
            continue

        at = q.get("answerType", "")
        for i, limb in enumerate(q.get("limbs", [])):
            key = limb_key(i, at)
            # カナ・数字どちらのキーでも拾えるよう両方試す
            exp = exps.get(key)
            if exp is None:
                alt = KATA[i] if not isinstance(key, str) and i < len(KATA) else (i + 1)
                exp = exps.get(alt)
            if not exp:
                continue
            if (limb.get("explanation") or "").strip():
                replaced += 1
            else:
                filled += 1
            limb["explanation"] = exp

    total_limbs = sum(len(q.get("limbs", [])) for q in questions)
    with_exp = sum(1 for q in questions for l in q.get("limbs", [])
                   if (l.get("explanation") or "").strip())

    print(f"解説を新規付与: {filled} 肢")
    print(f"解説を差し替え: {replaced} 肢")
    print(f"結果: 解説あり {with_exp} / {total_limbs} 肢")
    print(f"キャッシュHTMLなし: {no_cache} 問 / waku-a抽出できず: {no_match} 問")

    if args.dry_run:
        print("\n--dry-run のため書き込みませんでした。")
        return
    save_json(args.input, questions)
    print(f"\n{args.input} を更新しました。")


if __name__ == "__main__":
    main()
