/**
 * One of the person's prompts: its transcript row id, when it was sent (epoch
 * ms), and its text on one line, cut to PREVIEW_LIMIT characters.
 */
export type Prompt = { uuid: string; at: number; preview: string }

/** Which way the footer arrows and /where-were-we move through the prompts. */
export type Move = 'older' | 'newer' | 'last'

declare module 'claude-code' {
  interface PluginState {
    'where-were-we': {
      /** Every known prompt of this session, oldest first. */
      prompts: Shaped<Prompt[]>
      /** Index into `prompts` while navigating; null when not navigating. */
      cursor: number | null
      /** Each prompt row's timestamp, keyed by the row's id. */
      stamp: StateFamily<number | null>
      /** The session's transcript file, as the classic hook events report it. */
      transcriptPath: string | null
      /** The transcript the prompts were last backfilled from. */
      backfilledFrom: string | null
    }
  }
}
