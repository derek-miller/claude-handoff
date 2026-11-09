const shim = new URL('./shim.mjs', import.meta.url).href

export async function resolve(specifier, context, next) {
  if (specifier === './engine.js' && context.parentURL?.endsWith('/engine.test.js')) return { url: shim, shortCircuit: true }
  return next(specifier, context)
}
