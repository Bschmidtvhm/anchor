#!/usr/bin/env bash
# anchor-site.sh - the only supported way to change anchorcare.ai
#
#   ./scripts/anchor-site.sh check
#   ./scripts/anchor-site.sh publish "commit message"
#   ./scripts/anchor-site.sh sitemap        regenerate sitemap.xml (publish does this too)
#
# Must run on the Mac itself (needs network and the keychain credential helper).
# The sandboxed Claude VM has no network; git fetch/push there fail with a 403
# from the proxy. Run this via osascript:
#   do shell script "cd ~/anchor-landing && ./scripts/anchor-site.sh check"
#
# Why this exists: on 2026-07-26 five commits were made here and never pushed,
# and the last one left stale .git lock files that wedged the repo. Work moved
# to the GitHub web UI, main drifted 35 commits ahead of this clone, and nobody
# noticed for four months. This script makes that failure loud instead of silent.

set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

GIT=/usr/bin/git
LIVE="https://anchorcare.ai"
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
ok(){ printf '%s  OK   %s %s\n' "$GRN" "$OFF" "$*"; }
warn(){ printf '%s WARN  %s %s\n' "$YEL" "$OFF" "$*"; }
bad(){ printf '%s FAIL  %s %s\n' "$RED" "$OFF" "$*"; }
hr(){ printf -- '------------------------------------------------------------\n'; }

clear_stale_locks() {
  if pgrep -f '[g]it ' >/dev/null 2>&1; then
    warn "a git process is running; not touching lock files"
    return 0
  fi
  local n=0 lock
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    n=$((n+1)); warn "removing stale lock $lock"; rm -f "$lock"
  done < <(find .git -name '*.lock' 2>/dev/null)
  [ "$n" -eq 0 ] && ok "no stale git locks" || warn "cleared $n stale lock(s)"
  return 0
}

verify_live() {
  # Compare every tracked html file against what anchorcare.ai actually serves.
  local mismatch=0 f live_sum local_sum
  for f in $($GIT ls-files '*.html'); do
    live_sum=$(curl -fsS -m 25 "$LIVE/$f" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    local_sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
    if [ -z "$live_sum" ]; then warn "$f not reachable at $LIVE"; mismatch=$((mismatch+1))
    elif [ "$live_sum" != "$local_sum" ]; then bad "$f differs from live"; mismatch=$((mismatch+1)); fi
  done
  if [ "$mismatch" -eq 0 ]; then ok "all $( $GIT ls-files '*.html' | wc -l | tr -d ' ') html pages match the live site"; return 0; fi
  bad "$mismatch page(s) out of sync with live"; return 1
}

# --- sitemap -----------------------------------------------------------------
# sitemap.xml is generated, never hand-edited. It lists every tracked html page
# except: pages carrying <meta name="robots" content="noindex">, and the files
# in SITEMAP_EXCLUDE (known duplicate uploads that should not be indexed).
# 'publish' regenerates it before committing; 'check' fails if it is stale.
SITEMAP_EXCLUDE="insightsrealgovernance.html insights-vbid-to-ssbci_2.html"

sitemap_pages() {
  # prints "url<TAB>lastmod" for every page that belongs in the sitemap
  local f url lastmod
  for f in $($GIT ls-files '*.html'); do
    case " $SITEMAP_EXCLUDE " in *" $f "*) continue ;; esac
    grep -qiE '<meta[^>]+name="robots"[^>]+noindex' "$f" && continue
    case "$f" in
      index.html)    url="$LIVE/" ;;
      */index.html)  url="$LIVE/${f%index.html}" ;;
      *)             url="$LIVE/$f" ;;
    esac
    lastmod=$($GIT log -1 --format=%cs -- "$f" 2>/dev/null)
    [ -z "$lastmod" ] && lastmod=$(date +%F)
    printf '%s\t%s\n' "$url" "$lastmod"
  done | sort
}

render_sitemap() {
  local url lastmod
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
  while IFS=$'\t' read -r url lastmod; do
    printf '  <url>\n    <loc>%s</loc>\n    <lastmod>%s</lastmod>\n  </url>\n' "$url" "$lastmod"
  done < <(sitemap_pages)
  printf '</urlset>\n'
}

cmd_sitemap() {
  render_sitemap > sitemap.xml
  ok "sitemap.xml regenerated ($(grep -c '<loc>' sitemap.xml) pages)"
}

verify_sitemap() {
  # Fails if sitemap.xml is missing or does not match what the generator would
  # produce from the current tree (new page, removed page, or a page edited
  # since its lastmod). Fix: ./scripts/anchor-site.sh sitemap
  [ -f sitemap.xml ] || { bad "sitemap.xml is missing. Fix: ./scripts/anchor-site.sh sitemap"; return 1; }
  if ! diff -q <(render_sitemap) sitemap.xml >/dev/null 2>&1; then
    bad "sitemap.xml is STALE. Fix: ./scripts/anchor-site.sh sitemap"
    diff <(render_sitemap) sitemap.xml | grep '^[<>]' | grep -E 'loc|lastmod' | sed 's/^/        /' | head -10
    return 1
  fi
  ok "sitemap.xml matches the current pages ($(grep -c '<loc>' sitemap.xml) pages)"
  local live_sum local_sum
  live_sum=$(curl -fsS -m 25 "$LIVE/sitemap.xml" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
  local_sum=$(shasum -a 256 sitemap.xml | cut -d' ' -f1)
  if [ -z "$live_sum" ]; then warn "sitemap.xml not reachable at $LIVE"; return 1; fi
  [ "$live_sum" = "$local_sum" ] && ok "sitemap.xml matches the live site" || { bad "sitemap.xml differs from live"; return 1; }
}

cmd_check() {
  hr; echo "PREFLIGHT"; hr
  clear_stale_locks
  $GIT fetch origin --quiet 2>&1 || { bad "git fetch failed (no network? run this on the Mac, not the sandbox)"; return 1; }
  ok "fetched origin"

  local ahead behind
  ahead=$($GIT rev-list --count origin/main..main)
  behind=$($GIT rev-list --count main..origin/main)

  if [ "$behind" -gt 0 ]; then
    bad "local main is BEHIND origin by $behind commit(s)."
    echo "      Someone edited the site through the GitHub web UI or a Claude PR branch."
    echo "      Do NOT edit or force-push. Reconcile first:"
    echo "        git stash                # if you have local edits"
    echo "        git reset --hard origin/main"
    $GIT log --oneline main..origin/main | head -10 | sed 's/^/        /'
    return 1
  fi
  ok "not behind origin"

  if [ "$ahead" -gt 0 ]; then
    warn "local main is AHEAD by $ahead unpushed commit(s) - this is the 2026-07-26 failure:"
    $GIT log --oneline origin/main..main | sed 's/^/        /'
    echo "      Fix: ./scripts/anchor-site.sh publish"
  else ok "nothing unpushed"; fi

  if [ -n "$($GIT status --porcelain)" ]; then
    warn "uncommitted changes:"; $GIT status --short | sed 's/^/        /'
  else ok "working tree clean"; fi

  hr; echo "LIVE SITE"; hr
  local rc=0
  verify_live || rc=1
  hr; echo "SITEMAP"; hr
  verify_sitemap || rc=1
  return $rc
}

cmd_publish() {
  local msg="${1:-}"
  [ -z "$msg" ] && { bad 'usage: anchor-site.sh publish "commit message"'; return 1; }

  clear_stale_locks
  $GIT fetch origin --quiet 2>&1 || { bad "git fetch failed"; return 1; }
  if [ "$($GIT rev-list --count main..origin/main)" -gt 0 ]; then
    bad "REFUSING to publish: local is behind origin. Run 'check' and reconcile first."; return 1
  fi

  # sitemap.xml is derived from the page list; lastmod comes from git, so
  # regenerate it AFTER committing page edits and fold it into the same push.
  if [ -n "$($GIT status --porcelain)" ]; then
    $GIT add -A && $GIT commit -m "$msg" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" || { bad "commit failed"; return 1; }
    ok "committed"
  else warn "nothing to commit"; fi

  render_sitemap > sitemap.xml
  if [ -n "$($GIT status --porcelain sitemap.xml)" ]; then
    $GIT add sitemap.xml && $GIT commit -m "Regenerate sitemap.xml" --quiet || { bad "sitemap commit failed"; return 1; }
    ok "sitemap.xml regenerated and committed"
  else ok "sitemap.xml already current"; fi

  $GIT push origin main 2>&1 | tail -2 || { bad "PUSH FAILED - the commit exists locally but the site is NOT updated"; return 1; }
  [ "$($GIT rev-list --count origin/main..main)" -eq 0 ] || { bad "push did not land; still ahead"; return 1; }
  ok "pushed to origin/main"

  echo "waiting for GitHub Pages to rebuild..."
  local i
  for i in 1 2 3 4 5 6 7 8; do
    sleep 15
    if verify_live >/dev/null 2>&1 && verify_sitemap >/dev/null 2>&1; then ok "live site and sitemap now match local (after $((i*15))s)"; return 0; fi
    printf '  ... %ss\n' "$((i*15))"
  done
  warn "live site still differs after 120s. Pages may still be building; re-run 'check' shortly."
  verify_live; verify_sitemap
}

case "${1:-check}" in
  check)   cmd_check ;;
  publish) shift; cmd_publish "${1:-}" ;;
  sitemap) cmd_sitemap ;;
  *) echo "usage: $0 {check|publish \"message\"|sitemap}"; exit 2 ;;
esac
