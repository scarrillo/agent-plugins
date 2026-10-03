import type { On } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import {
  describeWhen,
  findListed,
  formatStamp,
  greetingText,
  listText,
  mergePrompts,
  moveCursor,
  parseListing,
  previousSession,
  promptFromLine,
} from '../hooks/prompts'

const NOW = new Date(2026, 9, 3, 12, 30, 0).getTime()
const SENT = new Date(2026, 9, 3, 12, 21, 0).getTime()

describe('formatStamp', () => {
  test('time only for today, date and time for older prompts', async () => {
    expect(formatStamp(SENT, NOW)).toBe('12:21:00')
    expect(formatStamp(new Date(2026, 9, 2, 18, 4, 11).getTime(), NOW)).toBe('2026-10-02 18:04:11')
  })
})

describe('promptFromLine', () => {
  const line = (row: object) => JSON.stringify(row)
  const at = '2026-10-03T19:22:25.260Z'

  test('reads typed prompts and queued prompts', async () => {
    expect(promptFromLine(line({ type: 'user', uuid: 'a', timestamp: at, message: { role: 'user', content: '  hi\n\n there ' } })))
      .toEqual({ uuid: 'a', at: Date.parse(at), preview: 'hi there' })
    expect(promptFromLine(line({
      type: 'user', uuid: 'b', timestamp: at,
      message: { role: 'user', content: [{ type: 'text', text: 'with image' }, { type: 'image' }] },
    }))).toEqual({ uuid: 'b', at: Date.parse(at), preview: 'with image' })
    expect(promptFromLine(line({
      type: 'attachment', uuid: 'c', timestamp: at,
      attachment: { type: 'queued_command', prompt: 'mid-turn', commandMode: 'prompt' },
    }))).toEqual({ uuid: 'c', at: Date.parse(at), preview: 'mid-turn' })
  })

  test('skips rows that are not the person typing', async () => {
    const skipped = [
      { type: 'user', uuid: 'd', timestamp: at, isMeta: true, message: { content: 'skill body' } },
      { type: 'user', uuid: 'e', timestamp: at, message: { content: [{ type: 'tool_result', content: 'x' }] } },
      { type: 'user', uuid: 'f', timestamp: at, message: { content: '<command-name>/clear</command-name>' } },
      { type: 'user', uuid: 'g', timestamp: at, isCompactSummary: true, message: { content: 'summary' } },
      { type: 'attachment', uuid: 'h', timestamp: at, attachment: { type: 'queued_command', prompt: 'n', commandMode: 'task-notification' } },
    ]
    for (const row of skipped) {
      expect(promptFromLine(line(row))).toBe(null)
    }
    expect(promptFromLine('{"cut off')).toBe(null)
  })
})

describe('navigation helpers', () => {
  test('moveCursor steps and clamps', async () => {
    expect(moveCursor(null, 3, 'older')).toBe(2)
    expect(moveCursor(2, 3, 'older')).toBe(1)
    expect(moveCursor(0, 3, 'older')).toBe(0)
    expect(moveCursor(1, 3, 'newer')).toBe(2)
    expect(moveCursor(2, 3, 'newer')).toBe(2)
    expect(moveCursor(0, 3, 'last')).toBe(2)
  })

  test('mergePrompts keeps known stamps and sorts by time', async () => {
    const merged = mergePrompts([{ uuid: 'b', at: 2, preview: 'b' }], [{ uuid: 'a', at: 1, preview: 'a' }, { uuid: 'b', at: 99, preview: 'b' }])
    expect(merged).toEqual([{ uuid: 'a', at: 1, preview: 'a' }, { uuid: 'b', at: 2, preview: 'b' }])
  })
})

describe('previousSession', () => {
  test('picks the latest other session in the project, its prompts only', async () => {
    const lines = [
      historyLine('old', 'first ever', 1_000),
      historyLine('recent', 'fix the bug', 5_000),
      historyLine('recent', '/where-were-we status', 5_500),
      historyLine('recent', '!git status', 5_600),
      historyLine('recent', 'now   ship\n it', 6_000),
      historyLine('current', 'this session', 9_000),
      historyLine('elsewhere', 'other project', 9_500, '/elsewhere'),
      'not json',
    ]
    expect(previousSession(lines, PROJECT, 'current')).toEqual({
      sessionId: 'recent',
      prompts: [
        { at: 5_000, preview: 'fix the bug' },
        { at: 6_000, preview: 'now ship it' },
      ],
    })
    expect(previousSession([historyLine('current', 'only me', 1)], PROJECT, 'current')).toBe(null)
  })
})

describe('greeting text', () => {
  test('says today, yesterday, or the date', async () => {
    expect(describeWhen(new Date(2026, 9, 3, 9, 5).getTime(), NOW)).toBe('today 09:05')
    expect(describeWhen(new Date(2026, 9, 2, 18, 4).getTime(), NOW)).toBe('yesterday 18:04')
    expect(describeWhen(new Date(2026, 8, 28, 7, 30).getTime(), NOW)).toBe('2026-09-28 07:30')
    // The first of the month's yesterday is the last of the month before.
    const first = new Date(2026, 10, 1, 8, 0).getTime()
    expect(describeWhen(new Date(2026, 9, 31, 23, 59).getTime(), first)).toBe('yesterday 23:59')
  })

  test('names the last prompt, cut to fit, and the command for more', async () => {
    const past = {
      sessionId: 's',
      prompts: [
        { at: 1, preview: 'earlier' },
        { at: new Date(2026, 9, 2, 18, 4).getTime(), preview: 'x'.repeat(80) },
      ],
    }
    expect(greetingText(past, NOW)).toBe(`Last here yesterday 18:04: “${'x'.repeat(59)}…” · /where-were-we last`)
    expect(greetingText({ sessionId: 's', prompts: [] }, NOW)).toBe(null)
  })
})

describe('listing', () => {
  const long = { uuid: 'l', at: new Date(2026, 9, 2, 18, 4, 11).getTime(), preview: 'x'.repeat(100) }
  const short = { uuid: 's', at: SENT, preview: 'short one' }

  test('lists full stamps and cut previews, and reads them back', async () => {
    const text = listText([long, short])
    expect(text).toBe(`- [2026-10-02 18:04:11] ${'x'.repeat(59)}\u2026\n- [2026-10-03 12:21:00] short one`)
    const lines = parseListing(`where-were-we: ${text}\nSome footer`)
    expect(lines.map(one => findListed([long, short], one)?.uuid)).toEqual(['l', 's'])
    expect(listText([])).toBe('No prompts yet.')
  })
})

const PROMPT_PROPS = { text: 'my prompt', origin: { kind: 'composer' }, isExpanded: false } as const
const TRANSCRIPT = '/cfg/projects/-work/current.jsonl'
const HISTORY = '/cfg/history.jsonl'
const PROJECT = '/work'

/** A history.jsonl line, as Claude Code's prompt history records one. */
const historyLine = (sessionId: string, display: string, at: number, project = PROJECT) =>
  JSON.stringify({ display, pastedContents: { 1: { content: 'SECRET' } }, timestamp: at, project, sessionId })

/** A transcript line for a prompt sent at local 12:mm:00 today. */
const promptLine = (uuid: string, minute: number) =>
  JSON.stringify({
    type: 'user',
    uuid,
    timestamp: new Date(2026, 9, 3, 12, minute, 0).toISOString(),
    message: { role: 'user', content: `prompt ${uuid}` },
  })

/**
 * Stands in for the engine beneath the plugin: the clock, the store, grep over a
 * transcript holding `lines`, logs, toasts and the engine's own rows. A
 * transcript row's scroll has no stub point in the kit, so jumps toast there.
 */
function engine(on: On, lines: string[], history: string[] = [], surface: 'terminal' | null = 'terminal') {
  /** The texts of the toasts shown, in order. */
  const toasts: string[] = []
  mock.clock(on, { now: NOW })
  mock.store(on)
  on('process.run', ($, e) => {
    const file = e.argv[0] === 'grep' ? e.argv.at(-1) : undefined
    const found = file === TRANSCRIPT ? lines : file === HISTORY ? history.filter(line => line.includes(`"project":"${PROJECT}"`)) : null
    const value = {
      exitCode: found === null ? 2 : found.length > 0 ? 0 : 1,
      stdout: found === null ? '' : found.join('\n') + '\n',
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    }
    return { value }
  })
  on('classic.SessionStart', () => ({}))
  on('session.id', () => ({ value: 'current' }))
  on('session.cwd', () => ({ value: PROJECT }))
  on('session.surface', () => ({ value: surface }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>ENGINE</Text>
  })

  return toasts
}

const startSession = ($: Engine) =>
  $.classic.SessionStart({ source: 'resume', transcript_path: TRANSCRIPT })

test('a resumed prompt row shows its time before the pointer', async ($, on) => {
  engine(on, [promptLine('p1', 21)])
  await startSession($)

  for (const surface of ['terminal', 'desktop'] as const) {
    const row = await $.ui.mount({
      plugin: 'where-were-we', surface, component: 'UserMessage', props: PROMPT_PROPS, requestId: 'p1',
    })
    expect(await row.find({ type: 'Text', text: /^12:21:00 ❯/ })).toBeDefined()
    expect(await row.find({ type: 'Text', text: 'my prompt' })).toBeDefined()
    await row.unmount()
  }
})

test('rows with no stamp, and other parties\' messages, are left to the engine', async ($, on) => {
  engine(on, [promptLine('p1', 21)])
  await startSession($)

  const unknown = await $.ui.mount({
    plugin: 'where-were-we', surface: 'terminal', component: 'UserMessage', props: PROMPT_PROPS, requestId: 'nope',
  })
  expect(await unknown.find({ type: 'Text', text: 'ENGINE' })).toBeDefined()
  await unknown.unmount()

  const notification = await $.ui.mount({
    plugin: 'where-were-we', surface: 'terminal', component: 'UserMessage', requestId: 'p1',
    props: { ...PROMPT_PROPS, origin: { kind: 'task-notification' } },
  })
  expect(await notification.find({ type: 'Text', text: 'ENGINE' })).toBeDefined()
  await notification.unmount()
})

test('the footer arrows and /where-were-we step through the prompts', async ($, on) => {
  engine(on, [promptLine('p1', 21), promptLine('p2', 22), promptLine('p3', 23)])
  await startSession($)

  const hint = { isDraft: false, isWorking: false, hint: '? for shortcuts' } as const
  const command = (args: string) =>
    $.command.run({
      command: 'where-were-we', args, origin: { kind: 'composer' },
      presentation: { isFullscreen: true, columns: 120 },
    })

  const idle = await $.ui.mount({ plugin: 'where-were-we', surface: 'terminal', component: 'PromptHint', props: hint })
  expect(await idle.find({ type: 'Text', text: 'ENGINE' })).toBeDefined()
  // Idle: the arrows alone, no position and no time.
  expect(await idle.find({ type: 'Button', key: 'older' })).toBeDefined()
  expect(await idle.find({ type: 'Text', text: /\d\/\d|\d\d:\d\d/ })).toBeUndefined()
  await idle.unmount()

  const position = (n: number) => new RegExp(`^\\s*${n}/3$`)
  for (const surface of ['terminal', 'desktop'] as const) {
    await command('newest')
    const footer = await $.ui.mount({ plugin: 'where-were-we', surface, component: 'PromptHint', props: hint })
    expect(await footer.find({ type: 'Text', text: position(3) })).toBeDefined()
    await footer.press({ key: 'older' })
    await footer.press({ key: 'older' })
    expect(await footer.find({ type: 'Text', text: position(1) })).toBeDefined()
    await footer.press({ key: 'older' })
    expect(await footer.find({ type: 'Text', text: position(1) })).toBeDefined()
    await footer.press({ key: 'newer' })
    expect(await footer.find({ type: 'Text', text: position(2) })).toBeDefined()
    await command('up')
    expect(await footer.find({ type: 'Text', text: position(1) })).toBeDefined()
    await footer.unmount()
  }
})

test('the bare command lists recent prompts newest last, each line jumping to its prompt', async ($, on) => {
  engine(on, [promptLine('p1', 21), promptLine('p2', 22), promptLine('p3', 23)])
  await startSession($)
  const command = (args: string) =>
    $.command.run({
      command: 'where-were-we', args, origin: { kind: 'composer' },
      presentation: { isFullscreen: true, columns: 120 },
    })

  const { text = '' } = await command('')
  expect(text).toBe(
    '- [2026-10-03 12:21:00] prompt p1\n- [2026-10-03 12:22:00] prompt p2\n- [2026-10-03 12:23:00] prompt p3',
  )

  const hint = { isDraft: false, isWorking: false, hint: '? for shortcuts' } as const
  for (const surface of ['terminal', 'desktop'] as const) {
    const listing = await $.ui.mount({
      plugin: 'where-were-we', surface, component: 'CommandOutput',
      props: { command: 'where-were-we', args: '', text, isErrored: false },
    })
    expect(await listing.find({ type: 'Button', text: '12:21:00  prompt p1' })).toBeDefined()
    await listing.press({ key: 'prompt-1' })
    await listing.unmount()

    const footer = await $.ui.mount({ plugin: 'where-were-we', surface, component: 'PromptHint', props: hint })
    expect(await footer.find({ type: 'Text', text: /^\s*2\/3$/ })).toBeDefined()
    await footer.unmount()
  }

  expect((await command('sideways')).text).toBe(
    'Usage: /where-were-we [up|down|newest|last|count [n]|order [chron|reverse]|greeting [on|off]|status]',
  )
})

test('count and order, kept in the mod store, shape the bare listing', async ($, on) => {
  engine(on, [promptLine('p1', 21), promptLine('p2', 22), promptLine('p3', 23)])
  await startSession($)
  const command = async (args: string) =>
    (
      await $.command.run({
        command: 'where-were-we', args, origin: { kind: 'composer' },
        presentation: { isFullscreen: true, columns: 120 },
      })
    ).text

  expect(await command('count')).toBe('Listing 6 prompts. Change it with /where-were-we count <1-50>.')
  expect(await command('order')).toBe('Listing chron (newest last). Change it with /where-were-we order chron|reverse.')

  expect(await command('count 2')).toBe('Listing 2 prompts from now on.')
  expect(await command('')).toBe('- [2026-10-03 12:22:00] prompt p2\n- [2026-10-03 12:23:00] prompt p3')

  expect(await command('order reverse')).toBe('Listing reverse (newest first) from now on.')
  expect(await command('')).toBe('- [2026-10-03 12:23:00] prompt p3\n- [2026-10-03 12:22:00] prompt p2')

  for (const bad of ['count 0', 'count 51', 'count 2.5', 'count many']) {
    expect(await command(bad)).toBe('The count is a whole number from 1 to 50.')
  }
  expect(await command('order sideways')).toBe('The order is chron (newest last) or reverse (newest first).')
})

test('last recaps the previous session in this project from the prompt history', async ($, on) => {
  const at = (minute: number) => new Date(2026, 9, 2, 18, minute, 0).getTime()
  engine(on, [], [
    historyLine('yesterday', 'refactor the auth middleware', at(1)),
    historyLine('yesterday', 'run the tests', at(4)),
    historyLine('current', 'today', NOW),
  ])
  await startSession($)
  const command = async (args: string) =>
    (
      await $.command.run({
        command: 'where-were-we', args, origin: { kind: 'composer' },
        presentation: { isFullscreen: true, columns: 120 },
      })
    ).text ?? ''

  const text = await command('last')
  expect(text).toBe(
    [
      'Previous session in this project, last active 2026-10-02 18:04:00 (2 prompts):',
      '- [2026-10-02 18:01:00] refactor the auth middleware',
      '- [2026-10-02 18:04:00] run the tests',
      'Resume it: claude --resume yesterday',
    ].join('\n'),
  )
  expect(text.includes('SECRET')).toBe(false)

  await command('order reverse')
  expect((await command('last')).split('\n')[1]).toBe('- [2026-10-02 18:04:00] run the tests')

  // Drawn as the engine's own row: its lines name another session's prompts.
  const row = await $.ui.mount({
    plugin: 'where-were-we', surface: 'terminal', component: 'CommandOutput',
    props: { command: 'where-were-we', args: 'last', text, isErrored: false },
  })
  expect(await row.find({ type: 'Text', text: 'ENGINE' })).toBeDefined()
  await row.unmount()
})

test('last says so when the project has no earlier session', async ($, on) => {
  engine(on, [], [historyLine('current', 'today', NOW)])
  await startSession($)
  const { text } = await $.command.run({
    command: 'where-were-we', args: 'last', origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 120 },
  })
  expect(text).toBe('No earlier session in this project.')
})

describe('startup greeting', () => {
  const yesterday = (minute: number) => new Date(2026, 9, 2, 18, minute, 0).getTime()
  const history = [
    historyLine('yesterday', 'refactor the auth middleware', yesterday(1)),
    historyLine('yesterday', 'run the tests', yesterday(4)),
  ]
  const greeting = 'Last here yesterday 18:04: “run the tests” · /where-were-we last'
  const start = ($: Engine, source: 'startup' | 'resume' | 'clear' | 'compact') =>
    $.classic.SessionStart({ source, transcript_path: TRANSCRIPT })

  test('a fresh start toasts how the previous session ended', async ($, on) => {
    const toasts = engine(on, [], history)
    await start($, 'startup')
    expect(toasts).toEqual([greeting])
  })

  test('a resume, /clear or compaction is no fresh start', async ($, on) => {
    const toasts = engine(on, [], history)
    for (const source of ['resume', 'clear', 'compact'] as const) {
      await start($, source)
    }
    expect(toasts).toEqual([])
  })

  test('a project with no earlier session is not greeted', async ($, on) => {
    const toasts = engine(on, [], [historyLine('current', 'today', NOW)])
    await start($, 'startup')
    expect(toasts).toEqual([])
  })

  test('a session with no surface (claude -p) is not greeted', async ($, on) => {
    const toasts = engine(on, [], history, null)
    await start($, 'startup')
    expect(toasts).toEqual([])
  })

  test('greeting on|off turns it off and on, kept in the mod store', async ($, on) => {
    const toasts = engine(on, [], history)
    const command = async (args: string) =>
      (
        await $.command.run({
          command: 'where-were-we', args, origin: { kind: 'composer' },
          presentation: { isFullscreen: true, columns: 120 },
        })
      ).text

    expect(await command('greeting')).toBe('The startup greeting is on. Change it with /where-were-we greeting on|off.')
    expect(await command('greeting off')).toBe('The startup greeting is off.')
    await start($, 'startup')
    expect(toasts).toEqual([])

    expect(await command('greeting maybe')).toBe('The greeting is on or off.')
    expect(await command('greeting on')).toBe('The startup greeting is on.')
    await start($, 'startup')
    expect(toasts).toEqual([greeting])
  })
})
