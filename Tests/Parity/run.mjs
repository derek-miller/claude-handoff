// node Tests/Parity/run.mjs <handoff-parity binary> [shard/total]
// Runs engine.test.js with every engine call served by Swift. With shard/total, runs only every
// total-th top-level test starting at shard (1-based), so CI can split the suite across runners.
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const [binary, shard = '1/1'] = process.argv.slice(2)
if (!binary) { console.error('usage: run.mjs <handoff-parity binary> [shard/total]'); process.exit(2) }
const [index, total] = shard.split('/').map(Number)
const root = path.resolve(import.meta.dirname, '../..')
const source = fs.readFileSync(path.join(root, 'Tests/Reference/engine.test.js'), 'utf8')
// Tests the harness cannot run against Swift. Each still runs in the plain Node suite.
const HARNESS_LIMITS = {
  // The Node work callback calls the engine's check/progress closures synchronously, which cannot cross the process boundary.
  'a twenty-second shutdown leaves moving and reopening their own phases': 'synchronous Swift closure',
  'long closed work gets a fresh bounded reopen wait': 'synchronous Swift closure',
  'polling without productive work stalls without racing unfinished mutations': 'synchronous Swift closure',
  // Counts concurrent cloud reads; the Swift engine reads artifacts one at a time.
  'artifact budget reservations remain shared across concurrent and throttled cloud analyses': 'sequential cloud reads'
}
const names = [...source.matchAll(/^test\((['"`])(.*?)\1/gm)].map(m => m[2]).filter((_, i) => i % total === index - 1)
  .filter(name => !(name in HARNESS_LIMITS) || (console.log(`skip (${HARNESS_LIMITS[name]}): ${name}`), false))
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')
const pattern = `^(${names.map(escape).join('|')})$`
const result = spawnSync(process.execPath, ['--import', './Tests/Parity/register.mjs', '--test',
  `--test-name-pattern=${pattern}`, 'Tests/Reference/engine.test.js'], {
  cwd: root, stdio: 'inherit', env: { ...process.env, PARITY_BIN: path.resolve(binary) }
})
process.exit(result.status ?? 1)
