---
name: transfer-session
description: Generate a prompt for transferring context to a fresh Claude Code session
---

# Transfer Session Context

## Task

Generate a complete prompt for continuing the current work in a new, clean Claude Code session. This is a universal command — works for any situation, not just plan execution.

## When to Use

- Session context is heavily loaded (long conversation, many files read)
- Model responses become slower or less focused
- You want to continue work with a fresh context
- Switching focus to a different aspect of the same project

## Steps

### 1. Analyze Current Session

Extract from the current session:

**A. Current State:**
- What directory/project are we working in?
- What files were created/modified?
- What's the current state of the work (builds? tests pass? errors?)

**B. Task Context:**
- What was the original task/goal?
- What approach was chosen and why?
- What has been completed?
- What remains to be done?

**C. Important Knowledge:**
- Key decisions made and their rationale
- Problems encountered and solutions found
- What was tried but didn't work
- Gotchas, edge cases, warnings
- Implicit understanding gained during the session

**D. Relevant Files:**
- Key files to read for context
- Documentation if any
- Config files that matter

### 2. Compose Prompt

Create a prompt with this structure:

```
## CONTEXT TRANSFER

This is a continuation of a previous session. Read this context carefully before proceeding.

## CRITICAL: DO NOT START WORKING

After loading all context below, you MUST:
1. Read all mentioned files
2. Confirm you understood the context (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start making changes
- Run commands (except reading files)
- Assume what to do next

**The user will tell you exactly what to do.**

## PROJECT

- **Directory:** `[working directory]`
- **Project:** [brief description of what this project is]

## ORIGINAL TASK

[What the user originally asked for / what we're trying to accomplish]

## CURRENT STATE

**Completed:**
- [x] Item 1
- [x] Item 2

**In progress / Remaining:**
- [ ] Item 3
- [ ] Item 4

**Status:** [builds/doesn't build, tests pass/fail, current errors if any]

## KEY FILES

Read these files first to understand the context:
- `path/to/file1` — [why it's important]
- `path/to/file2` — [why it's important]

## SESSION KNOWLEDGE

[Key decisions, problems solved, things that didn't work, gotchas — everything important that's not in the files]

## NEXT STEPS

[What was planned to do next / where we left off]

## INSTRUCTIONS

1. Read the key files listed above
2. Understand the context and current state
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any work
5. Ask: "What would you like me to work on?"
```

### 3. Adjust Based on Situation

**If working with a plan:**
- Add links to plan/design documents
- Include progress on plan tasks
- Reference the plan in NEXT STEPS

**If debugging:**
- Include error messages/stack traces
- List what was tried
- Note current hypothesis

**If exploring/researching:**
- Summarize findings so far
- List questions answered and remaining
- Note promising directions

### 4. Save and Report the Path

1. **Filename:** `docs/session-transfer-YYYY-MM-DD-HHMMSS.md` — always under the project's
   `docs/`, like every other prompt generator in this plugin; create the directory if it does
   not exist. Never `/tmp`: the fresh session has to find the file by a path relative to the
   project.

2. **Write to file:** Save the generated prompt. Do not commit it.

3. **Report the path — do NOT print the prompt.** The prompt lives in the file; echoing it
   into the chat only spends tokens. No clipboard either. Print exactly this and nothing more:

   ```
   Prompt saved: session transfer — <one line: what the work is about>
     relative: docs/session-transfer-YYYY-MM-DD-HHMMSS.md
     absolute: <realpath of that file>
   Open a fresh Claude Code session and hand it this file.
   ```

   `absolute` is `realpath <file>`.

## Tips for Good Transfers

- **Be concise:** New session doesn't need every detail, just what's actionable
- **Focus on "why":** Decisions and rationale are more valuable than listing every change
- **Include failures:** What didn't work saves time in the new session
- **State clearly what's next:** Don't make the new session guess where to continue
