#!/usr/bin/env bash
# Forwarder: this hook moved to kitchen, whose `kitchen setup` registers it. Kept so a
# stale settings entry or a memorized path still works until the code-config split closes.
exec ~/services/kitchen/src/claude_kitchen/hooks/capture-answer.sh "$@"
