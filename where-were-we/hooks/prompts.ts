import type { Prompt } from '../types'

/**
 * Fixed strings that only appear on the transcript lines that can be prompts
 * (quotes inside JSON string values are escaped, so tool output never matches).
 * grep pre-filters with these so a large transcript never crosses into the
 * plugin whole; `promptFromLine` makes the real decision.
 */
export const TRANSCRIPT_MARKERS = [
  '"type":"user","message":{"role":"user","content":"',
  '"type":"user","message":{"role":"user","content":[{"type":"text"',
  '"attachment":{"type":"queued_command"',
] as const

/** How much of a prompt's text is kept for the list (one line, whitespace collapsed). */
export const PREVIEW_LIMIT = 200

/** How much of a prompt the stored list text (what the model reads) shows. */
const LISTED_LIMIT = 60

const pad = (n: number) => String(n).padStart(2, '0')

const isSameDay = (a: Date, b: Date) =>
  a.getFullYear() === b.getFullYear() &&
  a.getMonth() === b.getMonth() &&
  a.getDate() === b.getDate()

/** `2026-10-02 18:04:11`, in local time. */
export function fullStamp(at: number): string {
  const sent = new Date(at)

  return (
    `${sent.getFullYear()}-${pad(sent.getMonth() + 1)}-${pad(sent.getDate())} ` +
    `${pad(sent.getHours())}:${pad(sent.getMinutes())}:${pad(sent.getSeconds())}`
  )
}

/** `12:21:00` for a prompt sent today, `2026-10-02 18:04:11` for an older one. */
export function formatStamp(at: number, now: number): string {
  const stamp = fullStamp(at)

  return isSameDay(new Date(at), new Date(now)) ? stamp.slice(11) : stamp
}

/** `text` cut to `limit` characters, with an ellipsis when cut. */
export function truncate(text: string, limit: number): string {
  if (text.length <= limit) {
    return text
  }

  return `${text.slice(0, Math.max(limit - 1, 0))}\u2026`
}

/** A prompt's text on one line, whitespace collapsed, cut to PREVIEW_LIMIT. */
export function toPreview(text: string): string {
  return text.replace(/\s+/g, ' ').trim().slice(0, PREVIEW_LIMIT)
}

/**
 * The bare command's output as the transcript stores it and the model reads
 * it: one `- [date time] preview` line per prompt, full dates so a listing
 * stays right on later days. `parseListing` reads it back for drawing.
 */
export function listText(recent: readonly Prompt[]): string {
  if (recent.length === 0) {
    return 'No prompts yet.'
  }

  return recent.map(prompt => `- [${fullStamp(prompt.at)}] ${truncate(prompt.preview, LISTED_LIMIT)}`).join('\n')
}

/** One line of a listing: its full stamp and the (possibly cut) preview. */
export type ListedLine = { stamp: string; preview: string }

/** The lines `listText` wrote; anything else in `text` is skipped. */
export function parseListing(text: string): ListedLine[] {
  return text.split('\n').flatMap(line => {
    const match = /^- \[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] (.*)$/.exec(line)
    return match?.[1] !== undefined && match[2] !== undefined ? [{ stamp: match[1], preview: match[2] }] : []
  })
}

/** The prompt a listing line names: same second, and its preview starts the same way. */
export function findListed(prompts: readonly Prompt[], line: ListedLine): Prompt | undefined {
  const head = line.preview.endsWith('\u2026') ? line.preview.slice(0, -1) : line.preview

  return prompts.find(prompt => fullStamp(prompt.at) === line.stamp && prompt.preview.startsWith(head))
}

function firstText(content: unknown): string | null {
  if (typeof content === 'string') {
    return content
  }
  if (!Array.isArray(content)) {
    return null
  }
  const first = content[0] as { type?: unknown; text?: unknown } | undefined

  return first?.type === 'text' && typeof first.text === 'string' ? first.text : null
}

type TranscriptRow = {
  type?: string
  uuid?: string
  timestamp?: string
  isMeta?: boolean
  isVisibleInTranscriptOnly?: boolean
  isCompactSummary?: boolean
  message?: { content?: unknown }
  attachment?: { type?: string; prompt?: unknown; commandMode?: string; isMeta?: boolean }
}

/**
 * The prompt a transcript line records, or null when it is no prompt of the
 * person's. Mirrors Claude Code's own rule: a non-meta user row whose first
 * block is text, or a queued prompt delivered mid-turn; text opening with `<`
 * (command records, notifications) is not a prompt.
 */
export function promptFromLine(line: string): Prompt | null {
  let row: TranscriptRow
  try {
    row = JSON.parse(line) as TranscriptRow
  } catch {
    return null
  }

  let text: string | null = null
  if (row.type === 'user') {
    if (row.isMeta || row.isVisibleInTranscriptOnly || row.isCompactSummary) {
      return null
    }
    text = firstText(row.message?.content)
  } else if (
    row.type === 'attachment' &&
    row.attachment?.type === 'queued_command' &&
    row.attachment.commandMode !== 'task-notification' &&
    !row.attachment.isMeta
  ) {
    text = firstText(row.attachment.prompt)
  }

  const trimmed = text?.trim() ?? ''
  if (trimmed === '' || trimmed.startsWith('<')) {
    return null
  }
  const at = Date.parse(row.timestamp ?? '')
  if (typeof row.uuid !== 'string' || Number.isNaN(at)) {
    return null
  }

  return { uuid: row.uuid, at, preview: toPreview(trimmed) }
}

/** `known` plus whichever of `found` it lacks, oldest first. */
export function mergePrompts(known: readonly Prompt[], found: readonly Prompt[]): Prompt[] {
  const ids = new Set(known.map(prompt => prompt.uuid))
  const added = found.filter(prompt => !ids.has(prompt.uuid))
  if (added.length === 0) {
    return [...known]
  }

  return [...known, ...added].sort((a, b) => a.at - b.at)
}

/**
 * Where a move lands in a list of `count` prompts from `cursor` (null: not
 * navigating, i.e. just past the newest). Clamped to the ends.
 */
export function moveCursor(cursor: number | null, count: number, move: 'older' | 'newer' | 'last'): number {
  const newest = count - 1
  if (move === 'last') {
    return newest
  }
  const from = cursor ?? count
  const to = move === 'older' ? from - 1 : from + 1

  return Math.min(Math.max(to, 0), newest)
}
