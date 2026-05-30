---
name: exec-plan-fresh-session
description: Generate a prompt for executing plan in a fresh Claude Code session
---

# Fresh Session Execution Prompt Generator

## Task

Generate a complete prompt for executing the current plan in a new, clean Claude Code session.

## Why Fresh Session

After brainstorming and planning, the current session context is cluttered with discussions. A fresh session provides:
- Clean context = better focus
- No distraction from planning discussions
- Model performs better with focused context

## Steps

### 1. Identify Documents

Find from current session context:
- **Design document:** `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
- **Plan document:** `docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md` or `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`

**If documents are not found:**
- Ask the user to specify the document paths explicitly
- Or search for alternative naming patterns (e.g., `docs/superpowers/specs/*design*`, `docs/superpowers/plans/*plan*`)

### 2. Generate Summary

Analyze the current session and extract information NOT in the documents but important for execution:
- Key decisions with rationale
- Rejected alternatives and why
- Edge cases and potential issues
- Warnings and limitations
- Implicit knowledge from discussions

### 3. Compose Prompt

Create a prompt with this structure:

```
## TASK

Execute the implementation plan for [feature name].

Use `/superpowers:subagent-driven-development` skill for execution.

## DOCUMENTS

- Design: `[path to design doc]`
- Plan: `[path to plan doc]`

Read both documents first.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:
1. Confirm you have loaded all context
2. Summarize your understanding briefly
3. **WAIT for user instruction before taking any action**

Do NOT begin implementation until the user explicitly tells you to start.

## SESSION CONTEXT

[Summary from step 2 - decisions, rejected alternatives, edge cases, warnings]

## PLAN QUALITY WARNING

The plan was written for a large task and may contain:
- Errors or inaccuracies in implementation details
- Oversights about edge cases or dependencies
- Assumptions that don't match the actual codebase
- Missing steps or incomplete instructions

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.

```

### 4. Save and Output

1. **Write to file:** Save prompt to `docs/superpowers/plans/YYYY-MM-DD-<topic>-execution-prompt.md` (same date and topic as plan)

2. **Display:** Show the full prompt content on screen

3. **Copy to clipboard:**
   - Linux: `cat <file> | xclip -selection clipboard` or `xsel --clipboard`
   - macOS: `cat <file> | pbcopy`
   - Detect OS automatically
   - **Note:** If xclip/xsel is not installed on Linux, suggest: `sudo apt install xclip` or `sudo apt install xsel`

4. **Notify:** "Prompt ready. Open a new Claude Code session and paste from clipboard (Ctrl+V / Cmd+V)"
