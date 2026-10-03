import type { On } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { findListed, formatStamp, listText, mergePrompts, moveCursor, parseListing, promptFromLine } from '../hooks/prompts'

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
const TRANSCRIPT = '/tmp/session.jsonl'

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
function engine(on: On, lines: string[]) {
  mock.clock(on, { now: NOW })
  mock.store(on)
  on('process.run', ($, e) => {
    const isGrep = e.argv[0] === 'grep' && e.argv.at(-1) === TRANSCRIPT
    const value = {
      exitCode: isGrep ? 0 : 2,
      stdout: isGrep ? lines.join('\n') + '\n' : '',
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    }
    return { value }
  })
  on('classic.SessionStart', () => ({}))
  on('ui.log', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>ENGINE</Text>
  })
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
  expect(await idle.find({ type: 'Text', text: /last 12:23:00/ })).toBeDefined()
  await idle.unmount()

  for (const surface of ['terminal', 'desktop'] as const) {
    await command('last')
    const footer = await $.ui.mount({ plugin: 'where-were-we', surface, component: 'PromptHint', props: hint })
    expect(await footer.find({ type: 'Text', text: /3\/3 12:23:00/ })).toBeDefined()
    await footer.press({ key: 'older' })
    await footer.press({ key: 'older' })
    expect(await footer.find({ type: 'Text', text: /1\/3 12:21:00/ })).toBeDefined()
    await footer.press({ key: 'older' })
    expect(await footer.find({ type: 'Text', text: /1\/3 12:21:00/ })).toBeDefined()
    await footer.press({ key: 'newer' })
    expect(await footer.find({ type: 'Text', text: /2\/3 12:22:00/ })).toBeDefined()
    await command('up')
    expect(await footer.find({ type: 'Text', text: /1\/3 12:21:00/ })).toBeDefined()
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
    expect(await footer.find({ type: 'Text', text: /2\/3 12:22:00/ })).toBeDefined()
    await footer.unmount()
  }

  expect((await command('sideways')).text).toBe('Usage: /where-were-we [up|down|last|count [n]|order [chron|reverse]|status]')
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
