# PR Review Rules

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
5. **Behavioral regressions** — silent changes to user-observable
   behavior that the PR doesn't call out: output format shifts,
   defaults that change for existing config, removed or renamed
   public API surface, timing characteristics in refactors, error
   class or message changes that downstream callers may be
   matching on, side-effect count changes (more or fewer events
   fired). Flag whenever a "refactor" or "cleanup" PR alters
   anything callers could observe — these are the easiest changes
   to slip through review because the diff looks innocuous.

Don't limit your review to these areas — flag anything that looks
wrong, fragile, or could be improved. Consider misuse, edge cases,
and risk. Suggest improvements scoped to the current review:
readability, maintainability, structure.

## Skip

- **Formatting nitpicks** — defer to project linters.
- **Unrelated refactors** — propose them as a follow-up todo
  rather than expanding the PR's scope.
