// node --import ./Tests/Parity/register.mjs --test Tests/Reference/engine.test.js
// Redirects the test suite's import of ./engine.js to the parity shim, which runs every comparable
// engine call against the Swift engine too. Off unless PARITY_BIN points at the handoff-parity binary.
import { register } from 'node:module'

if (process.env.PARITY_BIN) register('./hooks.mjs', import.meta.url)
