#!/usr/bin/env python3
"""Batch create GitHub labels, milestones, and issues from docs/ISSUES-DRAFT.md"""
import json
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

# Force UTF-8 on Windows (avoids cp950 errors with ✓/✗ chars)
try:
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
except AttributeError:
    pass

TOKEN = Path.home().joinpath('.github_pat').read_text(encoding='utf-8').strip()
REPO = 'www161616/new_erp'
API = 'https://api.github.com'


def api(method, path, data=None):
    url = f'{API}{path}'
    body = json.dumps(data).encode('utf-8') if data else None
    req = urllib.request.Request(
        url, method=method, data=body,
        headers={
            'Authorization': f'Bearer {TOKEN}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'Content-Type': 'application/json',
            'User-Agent': 'new-erp-issue-bot',
        }
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read() or b'{}')
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b'{}')
        except Exception:
            return e.code, {}


LABELS = [
    # Modules (blue)
    ('module:product', '0969da', '商品模組'),
    ('module:member', '0969da', '會員模組'),
    ('module:inventory', '0969da', '庫存模組'),
    ('module:purchase', '0969da', '採購模組'),
    ('module:sales', '0969da', '銷售模組'),
    ('module:order', '0969da', '訂單 / 取貨模組（待建）'),
    ('module:notification', '0969da', '通知模組（待建）'),
    ('module:ap', '0969da', '應付帳款 / 財務模組（待建）'),
    ('module:liff', '0969da', 'LIFF 前端（另案）'),
    ('module:cross', '0969da', '跨模組'),
    # Types (green)
    ('type:feature', '1a7f37', '新功能'),
    ('type:schema', '1a7f37', 'Schema 變動 / migration'),
    ('type:rpc', '1a7f37', 'RPC / stored procedure'),
    ('type:spike', '1a7f37', '技術驗證 / POC'),
    ('type:docs', '1a7f37', '文件 / PRD'),
    ('type:migration', '1a7f37', '資料遷移'),
    ('type:infra', '1a7f37', '基礎建設 / DevOps'),
    ('type:decision', '1a7f37', '待決策 / 討論'),
    ('type:bug', '1a7f37', 'Bug'),
    # Priority
    ('priority:p0', 'd73a4a', 'MVP 必要（v1 上線前）'),
    ('priority:p1', 'fbca04', '建議 v1 後做'),
    ('priority:p2', 'cfd3d7', '未來版本 / nice-to-have'),
    # Status
    ('status:blocked', 'b60205', '被其他 issue 卡住'),
    ('status:ready', '0e8a16', '可以開始'),
    ('status:in-progress', 'fbca04', '進行中'),
    ('status:review', '8957e5', '待 review'),
]

MILESTONES = [
    ('v0.1 設計完成', 'PRD + Open Questions 全部答完'),
    ('v0.2 Schema Finalize', 'schema 變動、RPC 實作完成'),
    ('Phase 1: Pilot 準備', 'Supabase deploy、API scaffold、pilot 門市選定'),
    ('Phase 1: Pilot 上線', '1 店 pilot + 總倉，2~4 週真實跑'),
    ('Phase 2: 漸進推廣', '每週 5~10 店上線、10~12 週全部'),
    ('Phase 3: 訂單流程完整', '訂單 / 通知 / LIFF 整合'),
]


def parse_issues_md(path: Path):
    """Parse docs/ISSUES-DRAFT.md ### sections into issue dicts."""
    text = path.read_text(encoding='utf-8')
    # Strip top-of-file metadata (before first "## 📝 Issues 清單")
    marker = '## 📝 Issues 清單'
    if marker in text:
        text = text.split(marker, 1)[1]
    issues = []
    # Find each ### block (not ## or ####)
    # Split by "^### " at line start
    blocks = re.split(r'\n### (?=\S)', text)
    for block in blocks[1:]:  # skip preamble
        lines = block.split('\n')
        title = lines[0].strip()
        # Skip non-issue sections like "🎯 快速統計" / "🚀 下一步建議"
        if title.startswith(('🎯', '🚀', '📌', '📅')):
            continue
        # Stop at next ## or end
        body_lines = []
        labels = []
        milestone = None
        in_body = True
        for line in lines[1:]:
            if line.startswith('## '):
                in_body = False
                break
            if not in_body:
                break
            # Extract labels
            m = re.match(r'^- \*\*Labels\*\*:\s*(.*)', line)
            if m:
                labels = re.findall(r'`([^`]+)`', m.group(1))
                body_lines.append(line)
                continue
            # Extract milestone
            m = re.match(r'^- \*\*Milestone\*\*:\s*(.*)', line)
            if m:
                milestone = m.group(1).strip()
                body_lines.append(line)
                continue
            body_lines.append(line)
        body = '\n'.join(body_lines).rstrip()
        issues.append({
            'title': title,
            'body': body,
            'labels': labels,
            'milestone': milestone,
        })
    return issues


def main():
    print(f'Target repo: {REPO}', flush=True)
    print(f'Token length: {len(TOKEN)}', flush=True)
    print()

    # 1. Create labels (idempotent — skip if exists)
    print('=== Creating labels ===')
    for name, color, desc in LABELS:
        code, resp = api('POST', f'/repos/{REPO}/labels',
                         {'name': name, 'color': color, 'description': desc})
        if code == 201:
            print(f'  ✓ created: {name}')
        elif code == 422 and 'already_exists' in json.dumps(resp):
            print(f'  - exists:  {name}')
        else:
            print(f'  ✗ FAIL ({code}): {name} — {resp.get("message", "")}')
        time.sleep(0.1)

    # 2. Create milestones → build title → number map
    print()
    print('=== Creating milestones ===')
    milestone_id = {}
    for title, desc in MILESTONES:
        code, resp = api('POST', f'/repos/{REPO}/milestones',
                         {'title': title, 'description': desc, 'state': 'open'})
        if code == 201:
            milestone_id[title] = resp['number']
            print(f'  ✓ created #{resp["number"]}: {title}')
        elif code == 422:
            # already exists — look it up
            _, existing = api('GET', f'/repos/{REPO}/milestones?state=all&per_page=100')
            for ms in existing:
                if ms['title'] == title:
                    milestone_id[title] = ms['number']
                    print(f'  - exists  #{ms["number"]}: {title}')
                    break
        else:
            print(f'  ✗ FAIL ({code}): {title} — {resp.get("message", "")}')
        time.sleep(0.1)

    # 3. Parse issues from md
    print()
    print('=== Parsing ISSUES-DRAFT.md ===')
    md_path = Path('docs/ISSUES-DRAFT.md')
    issues = parse_issues_md(md_path)
    print(f'  Found {len(issues)} issues')

    # 4. Create issues
    print()
    print('=== Creating issues ===')
    created = 0
    failed = 0
    for i, issue in enumerate(issues, 1):
        data = {
            'title': issue['title'],
            'body': issue['body'],
            'labels': issue['labels'],
        }
        if issue['milestone'] and issue['milestone'] in milestone_id:
            data['milestone'] = milestone_id[issue['milestone']]
        code, resp = api('POST', f'/repos/{REPO}/issues', data)
        if code == 201:
            created += 1
            print(f'  ✓ #{resp["number"]:3d} [{i}/{len(issues)}] {issue["title"][:70]}')
        else:
            failed += 1
            print(f'  ✗ FAIL ({code}) [{i}/{len(issues)}] {issue["title"][:70]}')
            print(f'       {resp.get("message", "")}')
        time.sleep(0.2)  # rate-limit friendly

    print()
    print(f'=== DONE: {created} created, {failed} failed ===')
    print(f'View: https://github.com/{REPO}/issues')


if __name__ == '__main__':
    main()
