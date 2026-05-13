# Default PR Review Rules

The pr-review-cycle skill loads this file during Step 3 (Summarize
and Prioritize) to drive its priority analysis. Projects can extend
or replace these defaults by adding a `review-cycle-rules.md` file
at their repo root — see SKILL.md's "Load the active review
ruleset" subsection for the merge semantics.

## Pay particular attention to

1. **Security** — secrets exposure, input validation, encryption,
   injection risks, authentication and authorization gaps.
2. **Performance** — hot-path or main-thread work, unnecessary
   recomputation, missed caching opportunities, scaling cliffs.
3. **Error handling** — silent failures, missing user-facing
   alerts, unhandled edge cases, retries that mask underlying
   failures.
4. **Accessibility & platform conventions** — defer to the reviewed
   project's platform best practices (WCAG for web, Apple HIG for
   iOS/macOS, Material guidelines for Android, etc.). Flag missing
   screen-reader, focus, contrast, or keyboard-navigation
   considerations where applicable.

Don't limit your review to these areas — flag anything that looks
wrong, fragile, or could be improved. Consider misuse, edge cases,
and risk. Suggest improvements scoped to the current review:
readability, maintainability, structure.

## Skip

- **Formatting nitpicks** — defer to project linters.
- **Unrelated refactors** — propose them as a follow-up todo
  rather than expanding the PR's scope.
