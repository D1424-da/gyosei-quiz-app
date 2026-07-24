#!/usr/bin/env python3
"""
quiz_utils.py
-------------
プロジェクト共通ユーティリティ。
パス定数・JSON読み書き・テキスト正規化など各スクリプトで重複する処理を集約する。
"""

import json
import re
from pathlib import Path

# ── パス定数 ──────────────────────────────────────────
PROJECT_ROOT   = Path(__file__).parent
OUTPUT_DIR     = PROJECT_ROOT / "output"
CACHE_HTML_DIR = PROJECT_ROOT / "cache" / "html"

ALL_QUESTIONS_JSON  = OUTPUT_DIR / "gyosyo_all_questions.json"
OXQUIZ_OUTPUT_JSON  = OUTPUT_DIR / "oxquiz_questions.json"
API_OXQUIZ_JSON     = OUTPUT_DIR / "api_oxquiz_questions.json"
AUDIT_REPORT_JSON   = OUTPUT_DIR / "cache_audit_report.json"


# ── JSON 読み書き ─────────────────────────────────────────
def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data, indent=2):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=indent)


# ── テキスト正規化 ────────────────────────────────────────
_FULLWIDTH_DIGITS = str.maketrans("０１２３４５６７８９", "0123456789")

def normalize_text(text):
    """全角数字→半角、連続空白→1つ、前後空白削除"""
    s = str(text or "").translate(_FULLWIDTH_DIGITS)
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def text_similarity(a, b):
    """2つのテキストの文字レベル類似度 (0.0～1.0)"""
    sa, sb = set(a), set(b)
    if not sa and not sb:
        return 1.0
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)
