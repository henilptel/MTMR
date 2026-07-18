#!/bin/bash
# Full MTMR rebuild pipeline: commit any pending source changes, push to the
# fork, wait for CI, download the artifact, fix the Sparkle.framework
# symlink/version issue, sign, install, reset TCC permissions, and verify
# it launches cleanly. One command instead of the whole manual sequence.
#
# Usage: scripts/rebuild-and-install.sh "commit message"
# (commit message only needed if there are uncommitted changes to push)

set -euo pipefail

REPO_DIR="$HOME/Work/Other/MTMR"
FORK_REPO="henilptel/MTMR"
APP_PATH="/Applications/MTMR.app"
BUNDLE_ID="Toxblh.MTMR"
COMMIT_MSG="${1:-}"

cd "$REPO_DIR"

echo "==> Checking for uncommitted changes..."
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git status --porcelain)" ]; then
  if [ -z "$COMMIT_MSG" ]; then
    echo "ERROR: uncommitted changes present but no commit message given." >&2
    echo "Usage: $0 \"commit message\"" >&2
    exit 1
  fi
  git add -A
  git commit -m "$COMMIT_MSG"
else
  echo "    no uncommitted changes."
fi

echo "==> Pushing to fork..."
git push myfork master
COMMIT_SHA=$(git rev-parse HEAD)
echo "    pushed $COMMIT_SHA"

echo "==> Waiting for 'Build artifact' workflow run to appear..."
RUN_ID=""
for i in $(seq 1 20); do
  RUN_ID=$(gh run list --repo "$FORK_REPO" --json databaseId,headSha,workflowName --limit 10 \
    --jq ".[] | select(.headSha==\"$COMMIT_SHA\" and .workflowName==\"Build artifact\") | .databaseId" | head -1)
  [ -n "$RUN_ID" ] && break
  sleep 3
done
if [ -z "$RUN_ID" ]; then
  echo "ERROR: could not find the workflow run for this commit." >&2
  exit 1
fi
echo "    run id: $RUN_ID"

echo "==> Waiting for build to complete..."
until [ "$(gh run view "$RUN_ID" --repo "$FORK_REPO" --json status --jq '.status')" = "completed" ]; do
  sleep 15
done
CONCLUSION=$(gh run view "$RUN_ID" --repo "$FORK_REPO" --json conclusion --jq '.conclusion')
if [ "$CONCLUSION" != "success" ]; then
  echo "ERROR: build failed (conclusion: $CONCLUSION). See: https://github.com/$FORK_REPO/actions/runs/$RUN_ID" >&2
  exit 1
fi
echo "    build succeeded."

echo "==> Downloading artifact..."
BUILD_DIR=$(mktemp -d)
gh run download "$RUN_ID" --repo "$FORK_REPO" --dir "$BUILD_DIR"
mv "$BUILD_DIR/MTMR-app" "$BUILD_DIR/MTMR.app"

echo "==> Quitting running MTMR (by PID, not by name)..."
PIDS=$(pgrep -f "MTMR.app/Contents/MacOS/MTMR" || true)
if [ -n "$PIDS" ]; then
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
fi
REMAINING=$(pgrep -f "MTMR.app/Contents/MacOS/MTMR" || true)
if [ -n "$REMAINING" ]; then
  echo "ERROR: MTMR still running after kill (pid(s): $REMAINING)." >&2
  exit 1
fi

echo "==> Preserving known-good Sparkle.framework from current install..."
KNOWN_GOOD_SPARKLE=""
if [ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
  KNOWN_GOOD_SPARKLE=$(mktemp -d)/Sparkle.framework
  cp -R "$APP_PATH/Contents/Frameworks/Sparkle.framework" "$KNOWN_GOOD_SPARKLE"
fi

echo "==> Installing new build..."
rm -rf "$APP_PATH"
cp -R "$BUILD_DIR/MTMR.app" "$APP_PATH"

if [ -n "$KNOWN_GOOD_SPARKLE" ]; then
  rm -rf "$APP_PATH/Contents/Frameworks/Sparkle.framework"
  cp -R "$KNOWN_GOOD_SPARKLE" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
fi

echo "==> Signing..."
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

# Auto-fix Sparkle.framework Versions/<letter> mismatch: launch, and if it
# crashes specifically with "Library not loaded ... Sparkle.framework/Versions/X",
# rename our Versions dir to match X and retry once.
#
# TCC reset happens INSIDE this function, immediately before each launch
# attempt (not once at the end) — every new code signature invalidates the
# previous grant, and if a Sparkle-fix re-sign happens between attempts the
# signature changes again. Resetting after launching (the original bug) let
# that first launch's fresh permission prompt/registration get wiped out
# again a few seconds later, so it never showed up in System Settings until
# a manual relaunch (with no reset following it) made it stick.
attempt_launch_and_fix() {
  tccutil reset AppleEvents "$BUNDLE_ID" > /dev/null 2>&1 || true
  tccutil reset Accessibility "$BUNDLE_ID" > /dev/null 2>&1 || true
  open "$APP_PATH"
  sleep 2
  if pgrep -f "MTMR.app/Contents/MacOS/MTMR" > /dev/null; then
    return 0
  fi

  LATEST_CRASH=$(ls -t "$HOME/Library/Logs/DiagnosticReports/"MTMR-*.ips 2>/dev/null | head -1)
  if [ -z "$LATEST_CRASH" ]; then
    return 1
  fi

  NEEDED_LETTER=$(python3 -c "
import json
with open('$LATEST_CRASH') as f:
    lines = f.read().split('\n', 1)
body = json.loads(lines[1])
reasons = body.get('termination', {}).get('reasons', [])
for r in reasons:
    if 'Sparkle.framework/Versions/' in r:
        print(r.split('Sparkle.framework/Versions/')[1].split('/')[0])
        break
" 2>/dev/null || true)

  if [ -z "$NEEDED_LETTER" ]; then
    return 1
  fi

  echo "    binary expects Sparkle Versions/$NEEDED_LETTER, fixing..."
  rm -f "$LATEST_CRASH"
  SPARKLE_VERSIONS="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions"
  CURRENT_LETTER=$(ls "$SPARKLE_VERSIONS" | grep -v Current | head -1)
  if [ "$CURRENT_LETTER" != "$NEEDED_LETTER" ]; then
    mv "$SPARKLE_VERSIONS/$CURRENT_LETTER" "$SPARKLE_VERSIONS/$NEEDED_LETTER"
    rm -f "$SPARKLE_VERSIONS/Current"
    ln -s "$NEEDED_LETTER" "$SPARKLE_VERSIONS/Current"
    codesign --force --deep --sign - "$APP_PATH"
  fi
  return 2  # signal "fixed, retry"
}

echo "==> Launching..."
if ! attempt_launch_and_fix; then
  RC=$?
  if [ "$RC" -eq 2 ]; then
    echo "==> Retrying launch after Sparkle.framework fix..."
    if ! attempt_launch_and_fix; then
      echo "ERROR: still failing after Sparkle.framework fix attempt. Check crash logs manually." >&2
      exit 1
    fi
  else
    echo "ERROR: MTMR failed to launch and crash log didn't match the known Sparkle.framework pattern. Check crash logs manually." >&2
    exit 1
  fi
fi

echo "==> Done. MTMR is running:"
ps aux | grep -i "MTMR.app/Contents/MacOS/MTMR" | grep -v grep

echo ""
echo "NOTE: TCC permissions were reset — you may see fresh Automation/Accessibility"
echo "prompts next time an action that needs them runs. Approve them."
