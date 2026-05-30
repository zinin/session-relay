---
name: pause-after-current-task
description: Use when executing a plan via superpowers:subagent-driven-development and you want a clean pause point. Signals the controller to fully finish the current task (spec review, code review, fixes, mark complete), then stop before dispatching the next task.
---

# Pause After Current Task

## Purpose

User signal to the controller running `superpowers:subagent-driven-development`: **finish the current task in full, then stop before the next task starts.** Use this to reach a clean checkpoint before switching to `/claude-mesh:continue-plan-fresh-session`, inspecting intermediate results, or freeing context.

## Override Authority

The `superpowers:subagent-driven-development` skill mandates continuous execution between tasks ("Do not pause to check in with your human partner between tasks"). **This command is the user's explicit authorization to break that rule** at one specific point — after the current task is fully closed. Treat it as user consent. Do not argue. Do not ask the user "are you sure".

## What "Current Task" Means

The task whose work is in progress right now. Concretely, one of:

- An implementer subagent has been dispatched for it (returning, in flight, BLOCKED, or NEEDS_CONTEXT), OR
- A spec reviewer / code quality reviewer subagent has been dispatched for it (in flight or returned with issues), OR
- The implementer is being re-dispatched to fix issues from either reviewer.

If none of the above applies, there is **no current task** (states A, E, or F below).

## Behavior

Identify your state in the per-task loop, then act.

### State A — Plan loaded, nothing dispatched yet

There is no current task. **Stop immediately.** Do NOT dispatch Task 1.

### State B — Implementer subagent in flight (or pending re-dispatch)

1. Let the implementer return.
2. Handle return status per the skill (DONE, DONE_WITH_CONCERNS, NEEDS_CONTEXT, BLOCKED).
3. On DONE or DONE_WITH_CONCERNS (with concerns addressed): proceed to State C.
4. On BLOCKED that cannot be resolved without architectural change or plan revision: escalate to user, stop here, mark the task BLOCKED in TodoWrite. That counts as "finishing" the current task for pause purposes — the user decides what to do next.

### State C — Implementer DONE → run spec compliance review

1. Dispatch spec reviewer (`spec-reviewer-prompt.md` from the skill).
2. If issues: implementer subagent fixes → spec reviewer re-reviews. Loop until ✅ approved.
3. Proceed to State D.

### State D — Spec review ✅ → run code quality review

1. Dispatch code quality reviewer (`code-quality-reviewer-prompt.md` from the skill).
2. If issues: implementer subagent fixes → code quality reviewer re-reviews. Loop until ✅ approved.
3. Mark task complete in TodoWrite.
4. **STOP.** Do NOT dispatch the next task.

### State E — Between tasks (previous marked complete, next not yet dispatched)

There is no current task in flight. **Stop immediately.** Do NOT dispatch the next task.

### State F — Out of per-task loop (final full-implementation reviewer or `finishing-a-development-branch`)

You're past the loop. **Stop wherever you are.** Do NOT advance to a new phase, do NOT start a new subagent. Report current state in the final summary.

## Checklist — What "Finish the Current Task" Includes

| Step | Required? |
|------|-----------|
| Let implementer subagent reach DONE (or escalate BLOCKED) | Yes |
| Spec compliance review | **Yes — never skip** |
| Spec re-review loop until ✅ approved | **Yes — never skip** |
| Code quality review | **Yes — never skip** |
| Code re-review loop until ✅ approved | **Yes — never skip** |
| Mark task complete in TodoWrite | Yes |
| Dispatch next task's implementer | **NO** |
| Final full-implementation review | **NO** |
| `superpowers:finishing-a-development-branch` | **NO** |

## Final Report

After stopping, output a checkpoint summary. Pick the variant matching your stop state.

**Normal completion (States B, C, D — current task closed cleanly):**

```
⏸ Пауза по /claude-mesh:pause-after-current-task — текущая задача доделана.

Только что закончили:
  Task <N>: <title>
    Implementer:  ✅ commits <hash>, <hash>
    Spec review:  ✅ approved
    Code review:  ✅ approved
    TodoWrite:    completed

Прогресс по плану:
  [x] Task 1: <title>
  [x] Task 2: <title>
  ...
  [x] Task <N>: <title>
  [ ] Task <N+1>: <следующая, НЕ начата>
  [ ] Task <N+2>: ...

Состояние сессии: чистый checkpoint — нет in-flight subagent'ов, всё закоммичено.

Что дальше:
  - Проверить промежуточный результат вручную
  - /claude-mesh:continue-plan-fresh-session — продолжить в новой сессии
  - Дать новую инструкцию
```

**State A (nothing started):**

```
⏸ Пауза по /claude-mesh:pause-after-current-task — выполнение ещё не начато.

План загружен, ни одна задача не dispatched. Останавливаюсь без действий.
Прогресс: 0 / N задач выполнено.

Что дальше — на ваше усмотрение.
```

**State E (between tasks):**

```
⏸ Пауза по /claude-mesh:pause-after-current-task — пауза перед следующей задачей.

Последняя завершённая задача: Task <N> (<title>)
Следующая (НЕ начата): Task <N+1> (<title>)

Состояние сессии: чистый checkpoint.

Что дальше:
  - Проверить промежуточный результат
  - /claude-mesh:continue-plan-fresh-session
  - Дать новую инструкцию
```

**State F (post-loop):**

```
⏸ Пауза по /claude-mesh:pause-after-current-task — команда вызвана после завершения per-task loop.

Все запланированные задачи выполнены. Текущая фаза: <final review / finishing-a-development-branch / другое>
Останавливаюсь, новые стадии не запускаю.

Дайте инструкции по дальнейшим шагам.
```

**BLOCKED escalation:**

```
⏸ Пауза по /claude-mesh:pause-after-current-task — текущая задача в состоянии BLOCKED.

Task <N>: <title>
Implementer статус: BLOCKED
Блокер: <description>

Стандартный цикл review не пройден — задача не закрыта. Нужно решение пользователя.
```

## Red Flags — STOP if you catch yourself doing this

| Anti-pattern | Reality |
|---|---|
| "Skip the spec review — user wants to stop fast" | "Finish the current task" includes both reviews. A skipped review is not a checkpoint, it's hidden tech debt. |
| "Skip the re-review after the fix" | The review loop IS the task. An unreviewed fix is not done. |
| "Auto-start the next task because it's small" | No. The whole point of this command is to stop *before* the next task. |
| "Auto-start the final full-implementation reviewer — the current task is the last one" | No. Final review is a separate phase, not part of the current task. |
| "User typed pause, so I should freeze mid-review" | No. Pause is graceful — drive the current task to a clean checkpoint, *then* stop. |
| "Mark the task complete even though the code reviewer has open issues" | No. Mark complete only after both reviews are ✅. |
| "User is in a hurry, I'll skip the report" | The report IS the user's checkpoint summary — it's why they paused. Always output. |
| "Ask the user to confirm before stopping" | No. The command itself is the consent. Confirming wastes context — exactly what they're trying to free. |

## Bottom Line

At the moment you stop, the repo and TodoWrite must be in **exactly the state they would be if `subagent-driven-development` had just finished the current task and were about to dispatch the next implementer — except you are NOT dispatching it.** That's the checkpoint the user wants.
