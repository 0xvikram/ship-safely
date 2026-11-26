// Health gate for the demo: 60 checkouts from 60 users with mixed carts; fails if more than 1% error.
// Prints one line, the only thing ship-safely keeps from it.
const base = process.env.CHECKOUT_URL || 'http://localhost:4321'
const n = Number(process.env.HEALTH_REQUESTS || 60)
let errors = 0, onNew = 0
await Promise.all(Array.from({ length: n }, async (_, i) => {
  const cart = [1999, 4200, 6500, 12000][i % 4]
  try {
    const r = await fetch(`${base}/checkout?user=ship-safely-probe-${i + 1}&cart=${cart}`)
    const d = await r.json()
    if (!r.ok) errors++
    else if (d.path === 'new') onNew++
  } catch { errors++ }
}))
const rate = (errors / n) * 100
console.log(`health: ${errors}/${n} errors (${rate.toFixed(1)}%), ${onNew} served the new path`)
process.exit(rate > 1 ? 1 : 0)
