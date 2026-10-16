---
description: Pause, resume or check STFU!Clawd's automatic window minimizing
argument-hint: pause | resume | status
allowed-tools: Bash(node:*)
---

!`node "${CLAUDE_PLUGIN_ROOT}/scripts/hook.js" ctl $ARGUMENTS`

Briefly relay the output of the command above to the user as-is, and do nothing else.
