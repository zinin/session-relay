---
name: continue-plan-fresh-session
description: Generate a prompt for continuing plan execution in a fresh Claude Code session
---

# Continue Plan in Fresh Session

## Task

Generate a prompt for continuing the current plan execution in a new, clean Claude Code session.

## When to Use

- You're executing a plan and completed some tasks
- Current session context is cluttered
- Need to continue with a fresh context without losing progress

## Steps

### 1. Determine Progress

From current session:
- Read the TodoWrite list (completed/pending tasks)
- Analyze session context to understand what was done
- Form a clear list of completed and remaining tasks

### 2. Find Documents

Locate from current session context:
- **Design document:** `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
- **Plan document:** `docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md` or `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`

**If not found:** Ask the user to specify paths explicitly.

### 3. Trim Completed Tasks from Plan

**Goal:** Reduce plan size so the next session doesn't waste context on already-done work.

For each completed task in the plan document:
1. Find the git commit(s) that implement it (`git log --oneline` on relevant files)
2. **Replace** the detailed implementation steps/instructions with a single line:
   ```
   ✅ Done — see commit(s): `abc1234`, `def5678`
   ```
3. Keep the task **title/heading** intact (for orientation), remove only the body/details

**Example before:**
```markdown
### Task 3: Add validation middleware
1. Create `src/middleware/validate.ts`
2. Import zod schemas from...
3. Add error handling that...
4. Register in `app.ts` after auth middleware...
```

**Example after:**
```markdown
### Task 3: Add validation middleware
✅ Done — see commit(s): `a1b2c3d`
```

**Important:**
- Edit the plan file directly (`docs/superpowers/plans/...`) — this is intentional, not destructive. The original content is preserved in git history.
- Do NOT trim tasks that are partially done or not started
- Commit the trimmed plan: `docs: trim completed tasks from plan for <topic>`

### 4. Collect Implicit Knowledge

Analyze the current session and extract information NOT in the documents:
- Decisions made during execution and their rationale
- Problems encountered and how they were resolved
- What was tried but didn't work
- Implementation nuances and details
- Warnings and things to watch out for

**Be concise:** Include only what's necessary, avoid cluttering the new session context.

### 5. Compose Prompt

Create a prompt with this structure:

```
## TASK

Continue executing the implementation plan for [feature name].

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start implementing tasks
- Make any code changes
- Run any commands (except reading documents)
- Assume what task to work on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: `[path to design doc]`
- Plan: `[path to plan doc]`

Read both documents to understand the full picture.

## PROGRESS

**Completed tasks:**
- [x] Task 1: brief description
- [x] Task 2: brief description

**Remaining tasks:**
- [ ] Task 3: brief description
- [ ] Task 4: brief description
...

## SESSION CONTEXT

[Implicit knowledge collected in step 3]

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

## INSTRUCTIONS

1. Read the documents listed above
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"

```

### 6. Save and Output

1. **Write to file:** Save prompt to `docs/superpowers/plans/YYYY-MM-DD-<topic>-continuation-prompt.md`

2. **Display:** Show the full prompt content on screen

3. **Copy to clipboard:**
   - Linux: `cat <file> | xclip -selection clipboard`
   - macOS: `cat <file> | pbcopy`
   - Detect OS automatically
   - **Note:** If xclip/xsel is not installed on Linux, suggest: `sudo apt install xclip`

4. **Notify:** "Prompt ready. Open a new Claude Code session and paste from clipboard (Ctrl+V / Cmd+V)"
