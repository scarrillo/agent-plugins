import { atom, memberOf, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Move, Prompt } from '../types'
import {
  TRANSCRIPT_MARKERS,
  findListed,
  formatStamp,
  fullStamp,
  greetingText,
  historyMarker,
  listText,
  mergePrompts,
  moveCursor,
  parseListing,
  previousSession,
  promptFromLine,
  toPreview,
  truncate,
} from './prompts'
import type { PastSession } from './prompts'

const COMMAND = 'where-were-we'
/** How many prompts the bare command lists until `/where-were-we count` sets it. */
const LISTED_DEFAULT = 6
const LISTED_MAX = 50
/** `chron` lists the newest prompt last (nearest the prompt), `reverse` first. */
const ORDERS = ['chron', 'reverse'] as const
type Order = (typeof ORDERS)[number]
const USAGE = `Usage: /${COMMAND} [up|down|newest|last|count [n]|order [chron|reverse]|greeting [on|off]|status]`
const POINTER = '❯'
/** The UserMessage origins that are the person's own prompts. */
const PERSON = new Set(['composer', 'bridge', 'sdk', 'unclassified'])

// The shape tag drops a list kept by an older version of this code (one
// without previews); the next backfill fills it again.
const prompts = atom({ plugin: 'where-were-we', key: 'prompts' } as const, [], { shape: 'with-preview' })
const cursor = atom({ plugin: 'where-were-we', key: 'cursor' } as const, null)
const stamp = atom({ plugin: 'where-were-we', key: 'stamp' } as const, null)
const transcriptPath = atom({ plugin: 'where-were-we', key: 'transcriptPath' } as const, null)
const backfilledFrom = atom({ plugin: 'where-were-we', key: 'backfilledFrom' } as const, null)

/** The latest log lines, for `/where-were-we status` (a reload starts it over). */
const recent: string[] = []

const debug = ($: EngineInterface, text: string) => {
  const now = Date.now()
  recent.push(`${formatStamp(now, now)} ${text}`)
  recent.splice(0, recent.length - 20)
  $.ui.log(`where-were-we: ${text}`, { to: 'debug' })
}

/** Stamps each prompt's row and adds the new ones to the navigation list. */
async function remember($: EngineInterface, found: readonly Prompt[]) {
  const known = new Set((await read($, prompts)).map(prompt => prompt.uuid))
  const added = found.filter(prompt => !known.has(prompt.uuid))
  for (const prompt of added) {
    await update($, memberOf(stamp, { requestId: prompt.uuid }), () => prompt.at)
  }
  if (added.length > 0) {
    await update($, prompts, list => mergePrompts(list, added))
  }

  return added.length
}

/**
 * Reads the prompts' timestamps out of the session's transcript: the rows a
 * `--resume` loads (loads are no appends, so nothing stamped them live) and
 * prompts queued mid-turn. grep pre-filters, so a transcript over the 4 MiB a
 * read may copy still works.
 */
async function backfill($: EngineInterface, path: string, why: string) {
  if (path === '') {
    return
  }
  const argv = ['grep', '-F', ...TRANSCRIPT_MARKERS.flatMap(marker => ['-e', marker]), '--', path]
  try {
    const run = await $.process.run(argv, { timeoutMs: 15_000 })
    if (run.exitCode > 1) {
      debug($, `backfill (${why}) grep failed with ${run.exitCode}: ${run.stderr.trim()}`)
      return
    }
    const found = run.stdout
      .split('\n')
      .map(promptFromLine)
      .filter((prompt): prompt is Prompt => prompt !== null)
    const added = await remember($, found)
    await update($, backfilledFrom, () => path)
    debug(
      $,
      `backfill (${why}): ${found.length} prompts in transcript, ${added} new` +
        (run.isStdoutTruncated ? ' (grep output truncated at 4 MiB)' : ''),
    )
  } catch (error) {
    debug($, `backfill (${why}) failed: ${String(error)}`)
  }
}

/** The one implementation behind the footer arrows, /where-were-we and the list. */
async function jump($: EngineInterface, move: Move) {
  const list = await read($, prompts)
  if (list.length === 0) {
    debug($, `jump ${move}: no prompts yet`)
    $.ui.toast('where-were-we: no prompts to jump to yet')
    return
  }
  const from = await read($, cursor)
  await goTo($, list, moveCursor(from, list.length, move), `jump ${move} from ${from ?? 'none'}`)
}

/**
 * How many prompts the bare command lists: the count kept in the mod's own
 * store (a JSON file of its own, not settings.json), else LISTED_DEFAULT.
 */
async function listCount($: EngineInterface) {
  const kept = await $.store.get('listCount')
  return typeof kept === 'number' && Number.isInteger(kept) && kept >= 1 && kept <= LISTED_MAX ? kept : LISTED_DEFAULT
}

/** The bare command's order, kept in the mod's store like the count; `chron` until set. */
async function listOrder($: EngineInterface): Promise<Order> {
  const kept = await $.store.get('listOrder')
  return ORDERS.find(order => order === kept) ?? 'chron'
}

/**
 * Claude Code's prompt history file: beside `projects/` in the configuration
 * directory the transcript lives under, so a custom CLAUDE_CONFIG_DIR is kept.
 */
async function historyPath($: EngineInterface) {
  const transcript = await read($, transcriptPath)
  const projects = transcript?.lastIndexOf('/projects/') ?? -1
  if (transcript && projects > 0) {
    return `${transcript.slice(0, projects)}/history.jsonl`
  }
  const home = await $.env.get('HOME')
  return home ? `${home}/.claude/history.jsonl` : null
}

/**
 * The previous session in this project from Claude Code's prompt history, or
 * the problem that kept it from being read. Shared by `last` and the greeting.
 */
async function findPreviousSession(
  $: EngineInterface,
  why: string,
): Promise<{ past: PastSession | null } | { problem: string }> {
  const path = await historyPath($)
  if (path === null) {
    return { problem: 'Could not find Claude Code\'s prompt history.' }
  }
  const project = await $.session.cwd()
  const run = await $.process.run(['grep', '-F', '-e', historyMarker(project), '--', path], { timeoutMs: 15_000 })
  if (run.exitCode > 1) {
    debug($, `${why}: grep failed with ${run.exitCode}: ${run.stderr.trim()}`)
    return { problem: `Could not read ${path}.` }
  }
  const past = previousSession(run.stdout.split('\n'), project, await $.session.id())
  debug($, `${why}: ${past ? `session ${past.sessionId}, ${past.prompts.length} prompts` : 'no earlier session'} in ${project}`)

  return { past }
}

/** Whether the startup greeting is on: kept in the mod's store, on until turned off. */
async function isGreetingOn($: EngineInterface) {
  return (await $.store.get('greeting')) !== false
}

/**
 * Shows, as a toast, when this project's previous session ended and its last
 * prompt. Only at a fresh start where something draws, and never in the way
 * of the session starting: any failure is logged and dropped.
 */
async function greet($: EngineInterface) {
  try {
    if (!(await isGreetingOn($)) || (await $.session.surface()) === null) {
      return
    }
    const found = await findPreviousSession($, 'greeting')
    const text = 'past' in found && found.past !== null ? greetingText(found.past, await $.clock.now()) : null
    if (text !== null) {
      $.ui.toast(text, { timeoutMs: 8_000 })
    }
  } catch (error) {
    debug($, `greeting failed: ${String(error)}`)
  }
}

/**
 * `/where-were-we last`: how the previous session in this project ended, from
 * Claude Code's prompt history (this session's transcript can't know), with
 * the command that resumes it. Listed with the same count and order.
 */
async function lastSession($: EngineInterface) {
  const found = await findPreviousSession($, 'last')
  if ('problem' in found) {
    return found.problem
  }
  const { past } = found
  if (past === null) {
    return 'No earlier session in this project.'
  }
  const ended = past.prompts.at(-1)?.at ?? 0
  const recentPrompts = past.prompts.slice(-(await listCount($)))
  const listed = (await listOrder($)) === 'reverse' ? recentPrompts.reverse() : recentPrompts
  const count = past.prompts.length

  return [
    `Previous session in this project, last active ${fullStamp(ended)} (${count} prompt${count === 1 ? '' : 's'}):`,
    listText(listed),
    `Resume it: claude --resume ${past.sessionId}`,
  ].join('\n')
}

/** Jumps to one prompt by its id, its place in the list read at the press. */
async function jumpTo($: EngineInterface, uuid: string) {
  const list = await read($, prompts)
  await goTo($, list, list.findIndex(prompt => prompt.uuid === uuid), 'list click')
}

/** Moves the cursor to `list[to]` and scrolls that prompt to the top of the view. */
async function goTo($: EngineInterface, list: readonly Prompt[], to: number, why: string) {
  const target = list[to]
  if (target === undefined) {
    debug($, `${why}: no prompt at ${to} of ${list.length}`)
    return
  }
  await update($, cursor, () => to)
  let deny: string | undefined
  try {
    deny = (await $.ui.scroll({ to: { requestId: target.uuid }, block: 'start' })).deny
  } catch (error) {
    deny = String(error)
  }
  debug($, `${why} -> ${to} of ${list.length} (${target.uuid})${deny ? ` failed: ${deny}` : ''}`)
  if (deny) {
    $.ui.toast(`where-were-we: can't scroll there (${deny})`)
  }
}

export const register: Register = on => {
  /** Row ids already logged as drawn without a stamp, so the debug log names each once. */
  const unstamped = new Set<string>()

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: COMMAND,
      description: 'List your recent prompts; up, down, newest jump through them; last recaps the previous session',
      argumentHint: '[up|down|newest|last|count [n]|order [chron|reverse]|greeting [on|off]|status]',
      immediate: true,
    })
    debug($, `loaded; utc offset ${-new Date().getTimezoneOffset()} min`)

    return next(e)
  })

  on('classic.SessionStart', async ($, e, next) => {
    await update($, transcriptPath, () => e.transcript_path)
    await backfill($, e.transcript_path, `session ${e.source}`)
    // Only a fresh start: a resume, /clear, compaction or reload is no return.
    if (e.source === 'startup') {
      await greet($)
    }

    return next(e)
  })

  // Covers a mod enabled mid-session: no SessionStart came, so the first
  // prompt after the load backfills the prompts sent before it.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    await update($, transcriptPath, () => e.transcript_path)
    if ((await read($, backfilledFrom)) !== e.transcript_path) {
      await backfill($, e.transcript_path, 'first prompt since load')
    }

    return next(e)
  })

  on('session.append', { door: 'prompt' }, async ($, e, next) => {
    const stored = await next(e)
    const isPerson = e.message.type === 'user' && !e.message.isMeta && PERSON.has(e.origin.kind)
    if (isPerson) {
      const text = e.message.content.flatMap(block => (block.type === 'text' ? [block.text] : [])).join(' ')
      const added = await remember($, [{ uuid: e.uuid, at: await $.clock.now(), preview: toPreview(text) }])
      await update($, cursor, () => null)
      debug($, `stamped prompt ${e.uuid} (${e.origin.kind})${added ? '' : ' (already known)'}`)
    }

    return stored
  })

  // Picks up prompts queued while a turn ran, which arrive as deliveries.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    const path = await read($, transcriptPath)
    if (path !== null) {
      await backfill($, path, 'turn complete')
    }

    return result
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      await update($, prompts, () => [])
      await update($, cursor, () => null)
      debug($, 'cleared prompt list on /clear')
    }

    return next(e)
  })

  on('command.run', { command: COMMAND }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    const [word = '', value, ...extra] = arg.split(/\s+/)
    if (word === 'count') {
      if (value === undefined) {
        return { text: `Listing ${await listCount($)} prompts. Change it with /${COMMAND} count <1-${LISTED_MAX}>.` }
      }
      const count = Number(value)
      if (extra.length > 0 || !Number.isInteger(count) || count < 1 || count > LISTED_MAX) {
        return { text: `The count is a whole number from 1 to ${LISTED_MAX}.` }
      }
      await $.store.set('listCount', count)
      debug($, `/${COMMAND} count ${count}`)
      return { text: `Listing ${count} prompts from now on.` }
    }
    if (word === 'order') {
      const describe = (order: Order) => (order === 'chron' ? 'newest last' : 'newest first')
      if (value === undefined) {
        const order = await listOrder($)
        return { text: `Listing ${order} (${describe(order)}). Change it with /${COMMAND} order chron|reverse.` }
      }
      const order = ORDERS.find(one => one === value)
      if (order === undefined || extra.length > 0) {
        return { text: `The order is chron (newest last) or reverse (newest first).` }
      }
      await $.store.set('listOrder', order)
      debug($, `/${COMMAND} order ${order}`)
      return { text: `Listing ${order} (${describe(order)}) from now on.` }
    }
    if (word === 'greeting') {
      if (value === undefined) {
        const state = (await isGreetingOn($)) ? 'on' : 'off'
        return { text: `The startup greeting is ${state}. Change it with /${COMMAND} greeting on|off.` }
      }
      if ((value !== 'on' && value !== 'off') || extra.length > 0) {
        return { text: 'The greeting is on or off.' }
      }
      await $.store.set('greeting', value === 'on')
      debug($, `/${COMMAND} greeting ${value}`)
      return { text: `The startup greeting is ${value}.` }
    }
    if (arg === 'last') {
      return { text: await lastSession($) }
    }
    if (arg === 'status') {
      const list = await read($, prompts)
      const now = await $.clock.now()
      const lines = [
        `prompts known: ${list.length}; cursor: ${await read($, cursor) ?? 'none'}; listing: ${await listCount($)}, ${await listOrder($)}; greeting: ${(await isGreetingOn($)) ? 'on' : 'off'}`,
        `transcript: ${await read($, transcriptPath) ?? 'not seen yet'}`,
        `backfilled from: ${await read($, backfilledFrom) ?? 'never'}`,
        `fullscreen: ${e.presentation.isFullscreen}; utc offset: ${-new Date().getTimezoneOffset()} min`,
        ...list.slice(-5).map(prompt => `  ${formatStamp(prompt.at, now)}  ${prompt.uuid}`),
        'recent log:',
        ...recent.map(line => `  ${line}`),
      ]
      return { text: lines.join('\n') }
    }
    if (arg === '') {
      const list = await read($, prompts)
      const listed = await listCount($)
      const order = await listOrder($)
      const recentPrompts = list.slice(-listed)
      debug($, `/${COMMAND}: listed ${recentPrompts.length} of ${list.length} prompts, ${order}`)
      return { text: listText(order === 'reverse' ? recentPrompts.reverse() : recentPrompts) }
    }
    const moves: Record<string, Move> = { up: 'older', down: 'newer', newest: 'last' }
    const move = moves[arg]
    if (move === undefined) {
      return { text: USAGE }
    }
    debug($, `/${COMMAND} ${arg}`)
    await jump($, move)

    return {}
  })

  // Draws the bare command's listing with each line a button that jumps to
  // its prompt. The stored text stays plain; each line is matched back to its
  // prompt by its second and preview, as the row carries no ids.
  on('ui.render', { component: 'CommandOutput', props: { command: COMMAND } }, async ($, e, next) => {
    const lines = e.props.args.trim() === '' ? parseListing(e.props.text) : []
    if (lines.length === 0) {
      return next(e)
    }
    const list = await read($, prompts)
    const now = await $.clock.now()
    const width = Math.max((e.viewport?.columns ?? 80) - 4, 20)
    const { Box, Button, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {lines.map((line, index) => {
          const target = findListed(list, line)
          if (target === undefined) {
            return <Text dimColor>{truncate(`${line.stamp}  ${line.preview}`, width)}</Text>
          }
          const label = truncate(`${formatStamp(target.at, now)}  ${target.preview}`, width)
          const { uuid } = target
          return <Button key={`prompt-${index}`} plain label={label} onPress={() => jumpTo($, uuid)} />
        })}
      </Box>
    )
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    const { origin, from, task } = e.props
    if (!PERSON.has(origin.kind) || from !== undefined || task !== undefined) {
      return next(e)
    }
    const at = await read($, memberOf(stamp, e))
    if (at === null) {
      // `placeholder` is the row the engine draws while a prompt is still being
      // submitted, before it has an id; it is replaced by the stamped row.
      if (e.requestId !== 'placeholder' && !unstamped.has(e.requestId)) {
        unstamped.add(e.requestId)
        debug($, `no stamp for prompt row ${e.requestId}; drawing the engine's row`)
      }
      return next(e)
    }
    const { Box, Text } = $.ui.resolve(e)
    const label = formatStamp(at, await $.clock.now())

    return (
      <Box flexDirection="row" marginTop={1} paddingRight={1} backgroundColor="userMessageBackground">
        <Box flexShrink={0}>
          <Text color="inactive">
            {label} {POINTER}{' '}
          </Text>
        </Box>
        <Box flexGrow={1} flexShrink={1}>
          <Text color="text">{e.props.text}</Text>
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    const list = await read($, prompts)
    const engine = await next(e)
    if (list.length === 0) {
      return engine
    }
    const at = await read($, cursor)
    const { Box, Button, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="row">
        {engine}
        <Box flexShrink={0} marginLeft={2}>
          <Button key="older" plain label={'↑'} dimColor onPress={() => jump($, 'older')} />
          <Text> </Text>
          <Button key="newer" plain label={'↓'} dimColor onPress={() => jump($, 'newer')} />
          {at !== null && <Text dimColor> {`${at + 1}/${list.length}`}</Text>}
        </Box>
      </Box>
    )
  })
}
