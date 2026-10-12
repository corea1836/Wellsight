#!/bin/bash
# Dangerous Command Guard — PreToolUse[Bash]
# Claude가 실행하려는 Bash 명령에 위험한 패턴이 있으면 차단.
# 입력은 stdin JSON으로 들어오며, exit 2여야 실제로 차단된다 (exit 1은 경고만 남기고 실행됨).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if echo "$COMMAND" | grep -qE 'rm\s+-rf|git\s+push\s+--force|git\s+reset\s+--hard|DROP\s+TABLE'; then
  echo 'BLOCKED: 위험한 명령어가 감지되었습니다.' >&2
  exit 2
fi

exit 0
