#!/usr/bin/env bash
set -u
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
export CODE_CONFIG_FLEET_HOSTS="$HERE/fixtures/fleet-hosts"
. "$HERE/../lib/fleet.sh"

# fleet_repo: tag → repo, repo → repo, unknown → passthrough
assert_eq "knightwatch-reviewer" "$(fleet_repo kwr)"                  "repo from tag"
assert_eq "knightwatch-reviewer" "$(fleet_repo knightwatch-reviewer)" "repo from dir name"
assert_eq "plow"                 "$(fleet_repo plow)"                 "repo plow"
assert_eq "newthing"             "$(fleet_repo newthing)"            "repo unknown passthrough"

# fleet_tag: tag → tag, repo → tag, unknown → dir name
assert_eq "kwr"      "$(fleet_tag kwr)"                  "tag from tag"
assert_eq "kwr"      "$(fleet_tag knightwatch-reviewer)" "tag from dir name"
assert_eq "cc"       "$(fleet_tag code-config)"        "tag cc"
assert_eq "newthing" "$(fleet_tag newthing)"             "tag unknown → dir name"

# map contents — adding or dropping a tag is a behavior change, so pin each one
assert_eq "life-dashboard" "$(fleet_repo ld)"   "ld → life-dashboard"
assert_eq "fd"             "$(fleet_tag fd)"    "fd no longer a tag (passthrough)"
assert_eq "ltmm-poc"       "$(fleet_repo ltmm)" "ltmm → ltmm-poc"
assert_eq "watchmepivot"   "$(fleet_repo wmp)"  "wmp → watchmepivot"
# The agent work lives in Tiago's upstream repo; we hold no fork of our own to tag.
assert_eq "plow-founder-agent" "$(fleet_repo founder)" "founder → plow-founder-agent"
assert_eq "founder"            "$(fleet_tag plow-founder-agent)" "tag founder"
assert_eq "the-plow-times-hermes-agent" "$(fleet_repo the-plow-times)" "the-plow-times → the-plow-times-hermes-agent"
assert_eq "the-plow-times"              "$(fleet_tag the-plow-times-hermes-agent)" "tag the-plow-times"

# fleet_user
assert_eq "alice"      "$(fleet_user wakeup)" "user wakeup"
assert_eq "dave"       "$(fleet_user rpi5b)" "user rpi5b"
assert_eq "bob"        "$(fleet_user rpi5)"   "user rpi5"
assert_eq "bob"        "$(fleet_user wmps-macbook-pro)" "user wmps-macbook-pro (prod Plow host)"
assert_eq "carol"      "$(fleet_user mba)"    "user mba"
_self=$(hostname -s 2>/dev/null || hostname)
_err=$(CODE_CONFIG_FLEET_HOSTS=/nonexistent fleet_user wakeup 2>&1 >/dev/null); _rc=$?
assert_rc 1 $_rc "missing host table fails"
case $_err in *"/nonexistent"*) _named=yes;; *) _named=no;; esac
assert_eq "yes" "$_named" "missing host table error names the path"

fleet_is_self "$_self"; assert_rc 0 $? "fleet_is_self matches this host"
fleet_is_self "$(printf '%s' "$_self" | tr '[:lower:]' '[:upper:]')"; assert_rc 0 $? "fleet_is_self case-folds"
fleet_is_self "not-this-host"; assert_rc 1 $? "fleet_is_self rejects a different host"
# An alias must read as self on the box it names, or a consumer passing it ssh's
# to this machine and gets a publickey denial. The map is faked so the assertion
# doesn't depend on which host the suite runs on, in a subshell so the override
# is contained — but the asserts run in the parent, whose counters they mutate.
# Rendered once rather than kept as a format string: a variable used AS printf's
# format would eat a literal % in a future row.
_fake_map=$(printf '%s so selfalias\notherbox so otheralias\n' "$_self")
( _fleet_hosts() { printf '%s\n' "$_fake_map"; }
  fleet_is_self selfalias ); assert_rc 0 $? "fleet_is_self resolves an alias to this host"
# ...without over-matching: another host's alias resolves and is still not self.
# The rc-1 case alone would also pass if the override never took effect, so pin
# that resolution actually happened.
assert_eq "otherbox" "$( _fleet_hosts() { printf '%s\n' "$_fake_map"; }; fleet_host otheralias )" \
  "fake map is live: otheralias → otherbox"
( _fleet_hosts() { printf '%s\n' "$_fake_map"; }
  fleet_is_self otheralias ); assert_rc 1 $? "fleet_is_self: another host's alias is not self"
fleet_is_self "$_self.local"; assert_rc 0 $? "fleet_is_self matches the macOS .local form"
fleet_user bogushost  >/dev/null 2>&1; assert_rc 1 $? "unknown host errors"
fleet_user rpi5screen >/dev/null 2>&1; assert_rc 1 $? "retired rpi5screen errors"

# fleet_host: canonical in → canonical out, alias in → canonical out. Aliases and
# repo tags share the name `wmp` by design (line 23 pins the repo side).
assert_eq "wmps-macbook-pro" "$(fleet_host wmps-macbook-pro)" "host: canonical passthrough"
assert_eq "wmps-macbook-pro" "$(fleet_host wmp)"              "host: alias wmp → wmps-macbook-pro"
assert_eq "bob"              "$(fleet_user wmp)"              "user: resolves via alias"
assert_eq "wakeup"           "$(fleet_host wakeup)"           "host: aliasless row passthrough"
fleet_host bogushost >/dev/null 2>&1; assert_rc 1 $? "fleet_host unknown errors"

# an unknown host names the alternatives — the bare error left the caller guessing
_err=$(fleet_host bogushost 2>&1 >/dev/null)
assert_contains "$_err" "wmps-macbook-pro"  "unknown host: lists known hosts"
assert_contains "$_err" "(alias: wmp)"      "unknown host: lists aliases"

# fleet_session: <tag><N>-<host>
assert_eq "plow0-wakeup" "$(fleet_session plow 0 wakeup)"                 "session slot 0"
assert_eq "plow4-mbp"    "$(fleet_session plow 4 mbp)"                    "session slot 4"
assert_eq "kwr3-wakeup"  "$(fleet_session knightwatch-reviewer 3 wakeup)" "session from dir name"

# fleet_dir: ~/Hacking/<repo><N> (tilde left literal for remote expansion)
assert_eq '~/Hacking/plow0'                 "$(fleet_dir plow 0)" "dir slot 0"
assert_eq '~/Hacking/plow4'                 "$(fleet_dir plow 4)" "dir slot 4"
assert_eq '~/Hacking/knightwatch-reviewer2' "$(fleet_dir kwr 2)"  "dir from tag"

assert_summary
