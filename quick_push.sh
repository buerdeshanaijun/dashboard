#!/bin/bash
# Fast dashboard update using GitHub Contents API (avoids git push delay)
# Usage: ./quick_push.sh "commit message"
# Requires: GITHUB_TOKEN in environment or .env

REPO="buerdeshanaijun/dashboard"
BRANCH="main"
FILE="data.json"
MSG="${1:-仪表盘快速更新}"

# Get token
if [ -z "$GITHUB_TOKEN" ]; then
  # Try to extract from git remote
  GITHUB_TOKEN=$(git config --get remote.origin.url | sed 's/.*ghp_//;s/@.*//')
  if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ 需要设置 GITHUB_TOKEN 环境变量"
    echo "可以从 git remote -v 中提取，或手动设置"
    exit 1
  fi
  GITHUB_TOKEN="ghp_$GITHUB_TOKEN"
fi

# Read current file
CONTENT=$(base64 -i data.json)
# Remove newlines from base64
CONTENT=$(echo "$CONTENT" | tr -d '\n')

# Get current SHA
SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/$REPO/contents/$FILE?ref=$BRANCH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))")

if [ -z "$SHA" ]; then
  echo "❌ 获取文件 SHA 失败"
  exit 1
fi

# Push update via API
echo "📤 通过 GitHub API 更新 $FILE..."
RESP=$(curl -s -X PUT -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"message\":\"$MSG\",\"content\":\"$CONTENT\",\"sha\":\"$SHA\",\"branch\":\"$BRANCH\"}" \
  "https://api.github.com/repos/$REPO/contents/$FILE")

if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('commit','') and 'ok' or 'fail')" 2>/dev/null | grep -q ok; then
  echo "✅ 更新成功！约 10-30 秒后部署完成"
  echo "   https://buerdeshanaijun.github.io/dashboard/"
else
  echo "❌ 更新失败:"
  echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null
fi
