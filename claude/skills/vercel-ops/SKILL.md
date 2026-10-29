---
name: vercel-ops
description: Use when working with Vercel deployments — searching logs, querying databases, debugging production issues, or checking deployment status
---

# Vercel Operations

Quick reference for common Vercel CLI operations. Always run from the project directory that's linked to Vercel (has `.vercel/project.json`).

## Priority

- `§ Logs`
- `§ Deployments`
- `§ Database (Turso / libSQL)`
- `§ Project-Specific Hints (example)`

## Logs

```bash
# Recent logs (last 10 minutes, production)
vercel logs --since 10m --no-follow --no-branch --environment production --limit 100

# Filter by level or status code
vercel logs --level error --since 24h --no-follow --json
vercel logs --status-code 500 --since 1h --no-follow --json

# Search for specific text (Vercel-side filter)
vercel logs -q 'search term' --since 1h --limit 500

# JSON output piped to local grep/jq for complex filtering
vercel logs --since 30m --no-follow --json --limit 300 2>&1 | grep -i "pattern"
vercel logs --since 1h --json --limit 500 > /tmp/vlogs.json && grep -c "pattern" /tmp/vlogs.json

# Expanded output with context
vercel logs --since 10m --no-follow --expand --limit 100 2>&1 | grep -A2 -B2 "pattern"
```

**Key flags:** `--no-follow` (don't stream), `--no-branch` (skip preview branches), `--json` (machine-readable), `--expand` (full log lines), `-q` (server-side search).

## Database (Turso / libSQL)

```bash
# Pull env vars from Vercel first (populates .env or .env.local)
vercel env pull

# Or source an existing .env manually
set -a && source .env.local && set +a

# Note: Vercel's Turso integration prefixes env vars with the project nickname
# e.g. myproject_TURSO_DATABASE_URL / myproject_TURSO_AUTH_TOKEN
URL="$myproject_TURSO_DATABASE_URL"
TOK="$myproject_TURSO_AUTH_TOKEN"

# Interactive shell (current turso CLI: URL is positional, auth via ?authToken= query param)
turso db shell "${URL}?authToken=${TOK}"

# One-shot query
turso db shell "${URL}?authToken=${TOK}" "SELECT * FROM usage LIMIT 10"
turso db shell "${URL}?authToken=${TOK}" .tables
```

**Legacy note:** older turso CLIs used `--url` / `--auth-token` flags; those were removed. Always use the `URL?authToken=TOKEN` form.

For **Vercel Postgres** projects, use `psql` with the connection string from `vercel env pull`.

## Deployments

```bash
vercel ls                              # List recent deployments
vercel inspect <url>                   # Deployment details
vercel env ls                          # Environment variables
vercel domains ls                      # Domains
vercel promote <deployment-url>        # Promote to production
```

## Project-Specific Hints (example)

Fill these in per linked project; the values below are placeholders.

- **Linked project:** `<project>-server` in `<project>/`
- **Domain:** `app.example.com`
- **DB env vars:** `<project>_TURSO_DATABASE_URL`, `<project>_TURSO_AUTH_TOKEN`
- **Tables:** e.g. `usage` (token tracking), `api_keys` (users), `clients`, `submissions` (audit log)
- **Admin endpoints:** e.g. `/api/admin/<resource>?username=X&since=1h`
- **Common log searches:** `grep -i "POST /api/<endpoint>"`, `grep -i "error"`, `grep "username"`
