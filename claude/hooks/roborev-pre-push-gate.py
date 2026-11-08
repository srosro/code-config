#!/usr/bin/env python3
# Forwarder: this hook moved to kitchen, whose `kitchen setup` registers it. Kept so a
# stale settings entry or a memorized path still works until the code-config split closes.
import os, sys
target = os.path.expanduser("~/services/kitchen/src/claude_kitchen/hooks/roborev-pre-push-gate.py")
os.execv(sys.executable, [sys.executable, target, *sys.argv[1:]])
