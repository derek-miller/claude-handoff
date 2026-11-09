// Shared wire format between the Node engine and the Swift parity harness (Sources/handoff-parity).
// Plain JSON plus tagged forms for what JSON cannot carry, with $id/$r so shared references survive.
//   undefined {"$u":1}  NaN/±Infinity {"$n":"NaN"}  bigint {"$b":"12"}  Set {"$s":[..]}  Map {"$m":[[k,v]..]}
//   Buffer {"$x":"hex"}  function {"$f":n}  Error {"$e":{message,name,props}}  object needing escape {"$o":{..}}
//   array with extra props {"$a":[..],"$p":{..}}  shared reference: first occurrence carries "$id", later ones {"$r":id}

// Engine values Node cannot rebuild travel as opaque tokens that turn back into the engine's own value in Swift.
export const RECIPE = Symbol('recipe')

export function encode(root, { functions = [], inputs = null } = {}) {
  const seen = new Map()
  const counts = new Map()
  const walk = (v) => {
    if (!v || typeof v !== 'object') return
    counts.set(v, (counts.get(v) ?? 0) + 1)
    if (counts.get(v) > 1) return
    if (Buffer.isBuffer(v)) return
    if (v instanceof Set) for (const x of v) walk(x)
    else if (v instanceof Map) for (const [k, x] of v) { walk(k); walk(x) }
    else for (const k of Object.keys(v)) walk(v[k])
  }
  walk(root)
  let next = 0
  const enc = (v) => {
    if (v === undefined) return { $u: 1 }
    if (typeof v === 'number') return Number.isFinite(v) ? v : { $n: String(v) }
    if (typeof v === 'bigint') return { $b: String(v) }
    if ((typeof v === 'function' || (v && typeof v === 'object')) && v[RECIPE]) return { $recipe: enc(v[RECIPE]) }
    if (typeof v === 'function') { functions.push(v); return { $f: functions.length - 1 } }
    if (v === null || typeof v !== 'object') return v
    if (seen.has(v)) return { $r: seen.get(v) }
    const shared = counts.get(v) > 1
    const id = shared ? next++ : null
    if (shared) seen.set(v, id)
    const tag = (body) => shared ? { $id: id, ...body } : body
    if (Buffer.isBuffer(v) || v instanceof Uint8Array) return tag({ $x: Buffer.from(v).toString('hex') })
    if (v instanceof Set) return tag({ $s: [...v].map(enc), ...props(v) })
    if (v instanceof Map) return tag({ $m: [...v].map(([k, x]) => [enc(k), enc(x)]), ...props(v) })
    if (v instanceof Error) return tag({ $e: { message: v.message, name: v.name, props: Object.fromEntries(Object.keys(v).map(k => [k, enc(v[k])])) } })
    // With `inputs`, plain objects and arrays carry their index so results can return the caller's own objects.
    const origin = inputs && (Array.isArray(v) || Object.getPrototypeOf(v) === Object.prototype) ? { $in: inputs.push(v) - 1 } : {}
    if (Array.isArray(v)) {
      const extra = Object.keys(v).filter(k => !/^\d+$/.test(k))
      const items = Array.from(v, enc)
      return shared || extra.length || inputs ? tag({ $a: items, ...(extra.length ? { $p: Object.fromEntries(extra.map(k => [k, enc(v[k])])) } : {}), ...origin }) : items
    }
    const body = Object.fromEntries(Object.keys(v).map(k => [k, enc(v[k])]))
    return shared || inputs || Object.keys(v).some(k => k.startsWith('$')) ? tag({ $o: body, ...origin }) : body
  }
  const props = (v) => {
    const keys = Object.keys(v)
    return keys.length ? { $p: Object.fromEntries(keys.map(k => [k, enc(v[k])])) } : {}
  }
  return enc(root)
}

export function decode(root, { functions = [], recipes = {}, inputs = null } = {}) {
  const refs = new Map()
  const dec = (v) => {
    if (Array.isArray(v)) return v.map(dec)
    if (!v || typeof v !== 'object') return v
    if ('$u' in v) return undefined
    if ('$n' in v) return Number(v.$n)
    if ('$b' in v) return BigInt(v.$b)
    if ('$f' in v) return functions[v.$f] ?? (() => {})
    if ('$sfn' in v) return () => { throw new Error('parity: a Swift closure was called from Node') }
    if ('$recipe' in v) {
      const recipe = dec(v.$recipe)
      const [kind, ...args] = recipe
      const value = recipes[kind] ? recipes[kind](...args) : {}
      value[RECIPE] = recipe
      return value
    }
    if ('$r' in v) return refs.get(v.$r)
    const keep = (x) => { if ('$id' in v) refs.set(v.$id, x); return x }
    const withProps = (x) => { if (v.$p) for (const [k, p] of Object.entries(v.$p)) x[k] = dec(p); return x }
    if ('$x' in v) return keep(Buffer.from(v.$x, 'hex'))
    if ('$s' in v) { const s = keep(new Set()); for (const x of v.$s) s.add(dec(x)); return withProps(s) }
    if ('$m' in v) { const m = keep(new Map()); for (const [k, x] of v.$m) m.set(dec(k), dec(x)); return withProps(m) }
    if ('$e' in v) { const e = keep(new Error(v.$e.message)); e.name = v.$e.name; for (const [k, p] of Object.entries(v.$e.props)) e[k] = dec(p); return e }
    // A result that is one of the caller's objects updates and returns that same object, as an in-process call would.
    const own = inputs && '$in' in v ? inputs[v.$in] : null
    if ('$a' in v) {
      const a = keep(own ?? [])
      const items = v.$a.map(dec)
      a.length = 0
      a.push(...items)
      return withProps(a)
    }
    const body = '$o' in v ? v.$o : v
    const o = keep(own ?? {})
    const entries = Object.entries(body).map(([k, x]) => [k, dec(x)])
    if (own) for (const k of Object.keys(own)) delete own[k]
    for (const [k, x] of entries) o[k] = x
    return o
  }
  return dec(root)
}
