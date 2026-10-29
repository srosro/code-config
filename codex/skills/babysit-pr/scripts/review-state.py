#!/usr/bin/env python3
"""Report mechanical KWR review coverage without interpreting findings."""

import argparse
import json
import re
import subprocess
import sys


SHA_PATTERNS = (
    re.compile(r"First review of (?:this PR|the PR).*?reviewed `([0-9a-f]{7,40})`", re.S),
    re.compile(r"Re-review of changes from `[^`]+` to `([0-9a-f]{7,40})`", re.S),
)
TRIGGER = re.compile(r"(?m)^/srosro-(?:update-)?review\s*$")
MARKER = "<!-- knightwatch-reviewer:auto-post -->"


def load_pr(args):
    if args.input:
        with open(args.input, encoding="utf-8") as handle:
            return json.load(handle)
    command = [
        "gh", "pr", "view", str(args.pr), "--repo", args.repo,
        "--json", "state,headRefOid,title,url,comments",
    ]
    return json.loads(subprocess.check_output(command, text=True))


def expected_actor(args):
    if args.actor:
        return args.actor.casefold()
    if args.input:
        raise ValueError("--actor is required with --input")
    return subprocess.check_output(
        ["gh", "api", "user", "--jq", ".login"], text=True
    ).strip().casefold()


def review_sha(body):
    for pattern in SHA_PATTERNS:
        match = pattern.search(body)
        if match:
            return match.group(1)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo")
    parser.add_argument("--pr", type=int)
    parser.add_argument("--actor", help="expected KWR GitHub actor; defaults to authenticated user")
    parser.add_argument("--input", help="read gh-pr-view-shaped JSON from a fixture")
    args = parser.parse_args()
    if not args.input and (not args.repo or args.pr is None):
        parser.error("--repo and --pr are required without --input")

    pr = load_pr(args)
    actor = expected_actor(args)
    comments = sorted(pr.get("comments", []), key=lambda item: item.get("createdAt", ""))
    reviews = []
    for comment in comments:
        body = comment.get("body", "")
        author = (comment.get("author") or {}).get("login", "").casefold()
        if MARKER not in body or author != actor:
            continue
        sha = review_sha(body)
        if sha:
            reviews.append((comment.get("createdAt", ""), sha, body))

    latest = reviews[-1] if reviews else None
    head = pr.get("headRefOid", "")
    review_time = latest[0] if latest else ""
    trigger_after = any(
        comment.get("createdAt", "") > review_time and TRIGGER.search(comment.get("body", ""))
        for comment in comments
    ) if latest else any(TRIGGER.search(comment.get("body", "")) for comment in comments)

    result = {
        "state": pr.get("state"),
        "title": pr.get("title"),
        "url": pr.get("url"),
        "head": head,
        "latest_review_sha": latest[1] if latest else None,
        "latest_review_at": review_time or None,
        "covers_head": bool(latest and head.startswith(latest[1])),
        "trigger_after_review": trigger_after,
        "latest_review_body": latest[2] if latest else None,
    }
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
