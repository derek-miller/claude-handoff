// Stands in for ./engine.js inside engine.test.js when PARITY_BIN is set. Each engine export the
// suite calls is executed by the Swift engine (handoff-parity serve) instead of Node, so the suite's own
// assertions check the native port. Callbacks, child processes and fetch are answered here, in Node, so the
// suite's mocks keep working. Calls the Swift side cannot see faithfully (the suite patched node:fs, timers
// or clocks for that call) fall back to Node and are counted.
import childProcess from 'node:child_process'
import fsSync from 'node:fs'
import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import readline from 'node:readline'
import * as real from '../Reference/engine.js'
import { decode, encode } from './serialize.mjs'

export * from '../Reference/engine.js'

const BIN = process.env.PARITY_BIN
// Engine-scoped limits recorded by one engine are honoured by the other, as one engine would honour its own.
process.env.PARITY_ENGINE_HASH ??= (await import('node:crypto')).createHash('sha256').update(fsSync.readFileSync(new URL('../Reference/engine.js', import.meta.url))).digest('hex')
process.env.PARITY_NODE_RUNTIME ??= process.versions.node
process.env.PARITY_NODE_HEAP ??= String((await import('node:v8')).getHeapStatistics().heap_size_limit)
const STATS = process.env.PARITY_STATS
const stats = { swift: {}, node: {}, reasons: {} }
const bump = (bucket, key) => { bucket[key] = (bucket[key] ?? 0) + 1 }
process.on('exit', () => { if (STATS) fsSync.appendFileSync(STATS, `${JSON.stringify(stats)}\n`) })

const snapshot = () => ({
  fsp: { ...fsp }, fsSync: { ...fsSync }, os: { ...os },
  now: Date.now, perf: performance.now, jsonParse: JSON.parse, setTimeout: globalThis.setTimeout, memoryUsage: process.memoryUsage,
  fetch: globalThis.fetch
})
// Child processes and fetch are answered by Node for the Swift side too, so patching them is fine.
const pristine = snapshot()
const changed = () => {
  const now = snapshot()
  for (const group of ['fsp', 'fsSync', 'os']) for (const key of Object.keys(pristine[group])) if (now[group][key] !== pristine[group][key]) return `${group}.${key}`
  for (const key of ['now', 'perf', 'jsonParse', 'setTimeout', 'memoryUsage']) if (now[key] !== pristine[key]) return key
  return null
}

// The Node `command()` helper, so restart flows see the suite's spawn mocks.
const command = (file, args, timeout) => new Promise((resolve) => {
  if (timeout <= 0) return resolve({ status: null, timedOut: true })
  const child = childProcess.spawn(file, args, { stdio: 'ignore' })
  let settled = false
  const finish = (result) => { if (!settled) { settled = true; clearTimeout(timer); resolve(result) } }
  const timer = setTimeout(() => { child.kill('SIGTERM'); finish({ status: null, timedOut: true }) }, timeout)
  child.once('error', () => finish({ status: null, timedOut: false }))
  child.once('exit', (status) => finish({ status, timedOut: false }))
})

// Node-side rebuilds of closures the Swift engine returns.
const processTable = (app) => {
  const options = { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 2000, env: { ...process.env, LC_ALL: 'C' } }
  const processes = childProcess.spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,lstart=,comm='], options)
  const commands = childProcess.spawnSync('/bin/ps', ['-axo', 'pid=,ppid=,lstart=,command='], options)
  if ([processes, commands].some((result) => result.error || result.status !== 0)) throw new Error('cannot inspect running workers')
  const directory = path.join(os.homedir(), '.claude/sessions')
  let registrations = []
  try {
    registrations = fsSync.readdirSync(directory).filter(name => /^\d+\.json$/.test(name)).flatMap(name => {
      try {
        const row = JSON.parse(fsSync.readFileSync(path.join(directory, name), 'utf8'))
        return row.pid === Number(name.slice(0, -5)) ? [row] : []
      } catch { return [] }
    })
  } catch {}
  return real.parseProcesses(processes.stdout, commands.stdout, app, registrations)
}
const recipes = { inspect: (processes, app) => () => processes ?? processTable(app) }

let active = 0
const UNSUPPORTED = Symbol('unsupported')
async function viaSwift(name, args) {
  const functions = []
  const inputs = []
  const request = { name, args: encode(args, { functions, inputs }) }
  const child = childProcess.spawn(BIN, ['serve'], { stdio: ['pipe', 'pipe', 'inherit'] })
  const lines = readline.createInterface({ input: child.stdout })
  const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`)
  const exited = new Promise((resolve) => child.once('exit', resolve))
  send(request)
  let outcome = null
  for await (const line of lines) {
    const message = JSON.parse(line)
    if ('result' in message || 'error' in message || 'unsupported' in message) { outcome = message; break }
    try {
      let value
      if ('callback' in message) {
        const target = functions[message.callback]
        const callArgs = decode(message.args, { functions, recipes, inputs })
        value = await target(...callArgs)
      } else if ('spawnSync' in message) {
        const [file, argv, options] = message.spawnSync
        const result = childProcess.spawnSync(file, argv, { encoding: 'utf8', ...options, env: options.env ?? process.env })
        value = { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '', error: result.error ? { message: result.error.message, code: result.error.code } : null }
      } else if ('command' in message) {
        value = await command(...message.command)
      } else if ('fetch' in message) {
        const { url, method, headers, body } = message.fetch
        const response = await globalThis.fetch(url, { method, headers, body: body == null ? undefined : body })
        const bytes = Buffer.from(await response.arrayBuffer())
        value = { status: response.status, ok: response.ok, headers: Object.fromEntries(response.headers), body: bytes.toString('hex') }
      }
      send({ value: encode(value, { functions, inputs }) })
    } catch (error) {
      send({ thrown: encode(error instanceof Error ? error : new Error(String(error)), { functions }) })
    }
  }
  child.stdin.end()
  const code = await exited
  if (!outcome) throw new Error(`handoff-parity ${name} exited ${code} without a result`)
  if ('unsupported' in outcome) return { [UNSUPPORTED]: outcome.unsupported }
  if ('args' in outcome) decode(outcome.args, { functions, recipes, inputs })
  if ('error' in outcome) throw decode(outcome.error, { functions, recipes, inputs })
  return decode(outcome.result, { functions, recipes, inputs })
}

const wrap = (name) => {
  const original = real[name]
  return function (...args) {
    const reason = !BIN ? 'disabled' : active ? 'nested' : changed()
    if (reason) {
      bump(stats.node, name)
      bump(stats.reasons, reason)
      return original(...args)
    }
    active++
    return viaSwift(name, args).finally(() => { active-- }).then((value) => {
      if (value && typeof value === 'object' && UNSUPPORTED in value) {
        bump(stats.node, name)
        bump(stats.reasons, `unsupported: ${value[UNSUPPORTED]}`)
        return original(...args)
      }
      bump(stats.swift, name)
      return value
    })
  }
}

// Synchronous exports run the harness synchronously; they take no callbacks.
function viaSwiftSync(name, args) {
  const functions = []
  const inputs = []
  const request = { name, args: encode(args, { functions, inputs }) }
  if (functions.length) return { fallback: 'callback' }
  const result = childProcess.spawnSync(BIN, ['serve'], { input: `${JSON.stringify(request)}\n`, encoding: 'utf8', maxBuffer: 1 << 30 })
  const line = result.stdout?.split('\n').find(Boolean)
  if (result.status !== 0 || !line) throw new Error(`handoff-parity ${name} failed: ${result.stderr}`)
  const outcome = JSON.parse(line)
  if ('unsupported' in outcome) return { fallback: `unsupported: ${outcome.unsupported}` }
  if ('args' in outcome) decode(outcome.args, { recipes, inputs })
  if ('error' in outcome) throw decode(outcome.error, { recipes, inputs })
  return { value: decode(outcome.result, { recipes, inputs }) }
}
const wrapSync = (name) => {
  const original = real[name]
  return function (...args) {
    const reason = !BIN ? 'disabled' : changed()
    const attempt = reason ? { fallback: reason } : viaSwiftSync(name, args)
    if ('fallback' in attempt) {
      bump(stats.node, name)
      bump(stats.reasons, attempt.fallback)
      return original(...args)
    }
    bump(stats.swift, name)
    return attempt.value
  }
}

// cloudClient returns an object of methods the suite calls directly, so it stays in Node; Swift engine calls
// reach that client through ordinary callbacks.
export const cloudClient = real.cloudClient

export const conversation = wrapSync('conversation')
export const conversationMatch = wrapSync('conversationMatch')
export const normalize = wrapSync('normalize')
export const semantic = wrapSync('semantic')
export const parseProcesses = wrapSync('parseProcesses')
export const pendingPresentation = wrapSync('pendingPresentation')
export const step = wrapSync('step')
export const receiptSummary = wrapSync('receiptSummary')
export const layout = wrapSync('layout')

export const accounts = wrap('accounts')
export const executeMove = wrap('executeMove')
export const finishHeld = wrap('finishHeld')
export const finishPending = wrap('finishPending')
export const finishWorkflow = wrap('finishWorkflow')
export const idleTimeouts = wrap('idleTimeouts')
export const inventory = wrap('inventory')
export const keepLocal = wrap('keepLocal')
export const leftovers = wrap('leftovers')
export const tidy = wrap('tidy')
export const move = wrap('move')
export const readReceipt = wrap('readReceipt')
export const restartPlan = wrap('restartPlan')
export const signedIn = wrap('signedIn')
export const sweep = wrap('sweep')
export const undo = wrap('undo')
export const verifyPlaced = wrap('verifyPlaced')
export const withDesktopRestart = wrap('withDesktopRestart')
export const writeNew = wrap('writeNew')
