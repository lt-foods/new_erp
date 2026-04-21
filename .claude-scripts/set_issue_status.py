#!/usr/bin/env python3
"""Set one or more issues' Status in the GitHub Project board.

Usage:
  python set_issue_status.py todo 12 13 14
  python set_issue_status.py in_progress 20
  python set_issue_status.py done 16 17

Requires PAT with `project` scope.
"""
import json
import sys
import time
import urllib.request
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
except AttributeError:
    pass

TOKEN = Path.home().joinpath('.github_pat').read_text(encoding='utf-8').strip()
OWNER = 'www161616'
REPO = 'new_erp'
PROJECT_ID = 'PVT_kwHOB2mPBc4BVRWm'
STATUS_FIELD_ID = 'PVTSSF_lAHOB2mPBc4BVRWmzhQuSyo'

STATUS_OPTIONS = {
    'todo':        'f75ad846',
    'in_progress': '47fc9ee4',
    'done':        '98236657',
}
ALIASES = {
    'in-progress': 'in_progress',
    'inprogress':  'in_progress',
    'doing':       'in_progress',
    'wip':         'in_progress',
    'complete':    'done',
    'completed':   'done',
}


def gql(query, variables=None):
    body = json.dumps({'query': query, 'variables': variables or {}}).encode()
    req = urllib.request.Request(
        'https://api.github.com/graphql', method='POST', data=body,
        headers={'Authorization': f'Bearer {TOKEN}',
                 'Content-Type': 'application/json',
                 'User-Agent': 'new-erp-issue-bot'},
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


LOOKUP = """
query($owner: String!, $repo: String!, $num: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $num) {
      id title
      projectItems(first: 10) {
        nodes { id project { id } }
      }
    }
  }
}
"""

UPDATE = """
mutation($proj: ID!, $item: ID!, $field: ID!, $opt: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $proj, itemId: $item, fieldId: $field,
    value: { singleSelectOptionId: $opt }
  }) { projectV2Item { id } }
}
"""


def set_status(issue_num: int, status: str):
    opt_id = STATUS_OPTIONS[status]
    result = gql(LOOKUP, {'owner': OWNER, 'repo': REPO, 'num': issue_num})
    issue = result.get('data', {}).get('repository', {}).get('issue')
    if not issue:
        print(f'  ✗ #{issue_num}: issue not found')
        return False
    # Find the project item belonging to our Project
    item_id = None
    for it in issue['projectItems']['nodes']:
        if it['project']['id'] == PROJECT_ID:
            item_id = it['id']
            break
    if not item_id:
        print(f'  ✗ #{issue_num}: not in project (add it first)')
        return False
    result = gql(UPDATE, {
        'proj': PROJECT_ID,
        'item': item_id,
        'field': STATUS_FIELD_ID,
        'opt': opt_id,
    })
    if 'errors' in result:
        print(f'  ✗ #{issue_num}: {result["errors"][0].get("message", "")}')
        return False
    print(f'  ✓ #{issue_num} → {status}: {issue["title"][:60]}')
    return True


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        print(f'Valid statuses: {list(STATUS_OPTIONS.keys())}')
        sys.exit(1)
    status_raw = sys.argv[1].lower()
    status = ALIASES.get(status_raw, status_raw)
    if status not in STATUS_OPTIONS:
        print(f'Invalid status: {status_raw}. Use: {list(STATUS_OPTIONS.keys())}')
        sys.exit(1)
    issue_nums = [int(a) for a in sys.argv[2:]]
    print(f'Target status: {status}')
    print(f'Issues: {issue_nums}')
    print()
    ok = 0
    for n in issue_nums:
        if set_status(n, status):
            ok += 1
        time.sleep(0.15)
    print()
    print(f'=== DONE: {ok}/{len(issue_nums)} updated ===')


if __name__ == '__main__':
    main()
