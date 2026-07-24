#!/usr/bin/env python3
"""
normalize_categories.py
-----------------------
行政書士試験の出題構造に合わせてカテゴリを統一する。

使い方:
  python3 normalize_categories.py [--dry-run]
  python3 normalize_categories.py --input output/oxquiz_questions.json

変換結果:
  75 種類 -> 17 種類
  topCategory フィールドも追加（法令科目 / 一般知識等）
"""

import json
import argparse
from collections import Counter
from quiz_utils import load_json, save_json, OXQUIZ_OUTPUT_JSON


def build_maps():
    cat = {}

    def add(targets, dest):
        for t in targets:
            cat[t] = dest

    # 基礎法学
    add(['基礎法学', '法令用語', '判決文の理解', '公法と私法'], '基礎法学')

    # 憲法
    add([
        '憲法', '憲法・その他', '憲法の概念', '憲法9条', '憲法・議員', '憲法・精神的自由',
        '憲法と私法上の行為',
        '基本的人権', '人権', '幸福追求権など', 'プライバシー権', '新しい人権',
        '法の下の平等', '外国人の人権',
        '精神的自由', '学問の自由', '信教の自由', '経済的自由', '職業選択の自由',
        '社会権', '生存権', '参政権', '選挙権・選挙制度', '投票価値の平等', '教科書検定制度',
        '権力分立', '国会', '内閣', '天皇・内閣', '財政', '司法の限界', '国民審査',
    ], '憲法')

    # 行政法（総論）
    add([
        '行政法', '行政法の判例', '行政立法', '行政裁量', '行政調査',
        '行政代執行法', '執行罰', '無効な行政行為', '無効と取消し', '取消しと撤回',
    ], '行政法（総論）')

    add(['行政手続法'], '行政手続法')
    add(['行政不服審査法', '行政不服審査法等', '行服法・行訴法'], '行政不服審査法')
    add(['行政事件訴訟法', '行政事件訴訟'], '行政事件訴訟法')
    add(['国家賠償法', '損失補償'], '国家賠償法')
    add(['地方自治法'], '地方自治法')

    # 民法
    add(['民法', '民法：総則'], '民法（総則）')
    add(['民法：物権'], '民法（物権）')
    add(['民法：債権', '民法・債権'], '民法（債権）')
    add(['民法：親族'], '民法（親族・相続）')

    add(['商法', '会社法'], '商法・会社法')
    add(['行政書士法'], '行政書士法')

    # 一般知識等
    add(['基礎知識', '基礎知識・政治', '基礎知識・社会', '基礎知識・経済'], '政治・経済・社会')
    add([
        '基礎知識・情報通信', '基礎知識・個人情報保護', '個人情報保護法',
        '情報公開法', '公文書管理法', '基礎知識・公文書管理法', '住民基本台帳法',
    ], '情報通信・個人情報保護')
    add(['基礎知識・その他'], '一般知識（その他）')

    top = {}
    for c in [
        '基礎法学', '憲法', '行政法（総論）', '行政手続法', '行政不服審査法',
        '行政事件訴訟法', '国家賠償法', '地方自治法',
        '民法（総則）', '民法（物権）', '民法（債権）', '民法（親族・相続）',
        '商法・会社法', '行政書士法',
    ]:
        top[c] = '法令科目'
    for c in ['政治・経済・社会', '情報通信・個人情報保護', '一般知識（その他）']:
        top[c] = '一般知識等'

    return cat, top


CATEGORY_ORDER = [
    '基礎法学', '憲法', '行政法（総論）', '行政手続法', '行政不服審査法',
    '行政事件訴訟法', '国家賠償法', '地方自治法',
    '民法（総則）', '民法（物権）', '民法（債権）', '民法（親族・相続）',
    '商法・会社法', '行政書士法',
    '政治・経済・社会', '情報通信・個人情報保護', '一般知識（その他）',
]


def main():
    parser = argparse.ArgumentParser(description='カテゴリを正規化する')
    parser.add_argument('--input',   default='output/oxquiz_questions.json')
    parser.add_argument('--output',  default='output/oxquiz_questions.json')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()

    cat_map, top_map = build_maps()

    data = load_json(args.input)

    before = Counter(q.get('category', '') for q in data)
    changed = 0
    unmapped = set()

    for q in data:
        old = q.get('category', '')
        new = cat_map.get(old, old)
        top = top_map.get(new)
        if top is None:
            unmapped.add(old)
            top = '法令科目'
        if old != new:
            changed += 1
        q['category']    = new
        q['topCategory'] = top

    after = Counter(q['category'] for q in data)

    print(f'変換: {changed} 問 / カテゴリ数: {len(before)} -> {len(after)} 種類')
    print()
    print('=== 変換後カテゴリ ===')
    for cat in CATEGORY_ORDER:
        if cat in after:
            top = top_map.get(cat, '?')
            print(f'  [{top}]  {cat}  {after[cat]} 問')
    others = [(c, v) for c, v in sorted(after.items(), key=lambda x: -x[1])
              if c not in CATEGORY_ORDER]
    if others:
        print('  --- 未マッピング ---')
        for c, v in others:
            print(f'  {c}  {v} 問')
    if unmapped:
        print(f'\n警告: topCategory未設定 = {sorted(unmapped)}')

    if not args.dry_run:
        save_json(args.output, data)
        print(f'\n保存: {args.output}')
    else:
        print('\n(--dry-run: ファイル未更新)')


if __name__ == '__main__':
    main()
