import assert from 'node:assert/strict'
import { readdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import MiniSearch from 'minisearch'
import { boostReadingDocument, tokenizeReadingText } from './search-policy.mjs'

const chunks = new URL('../.vitepress/dist/assets/chunks/', import.meta.url)
const indexFile = (await readdir(chunks)).find(file => /^@localSearchIndexroot\..*\.js$/.test(file))
assert.ok(indexFile, 'The built reading site must contain its local search index')
const serialized = (await import(new URL(indexFile, chunks).href)).default
const index = MiniSearch.loadJSON(serialized, {
  fields: ['title', 'titles', 'text'],
  storeFields: ['title', 'titles'],
  tokenize: tokenizeReadingText,
  searchOptions: { fuzzy: 0.2, prefix: true, boost: { title: 4, text: 2, titles: 1 }, boostDocument: boostReadingDocument },
})

for (const [query, expected] of [
  ['幂等', /\/(?:book\/(?:ch\d\d-|glossary)|labs\/L\d\d-)/],
  ['租约', /\/(?:book\/(?:ch\d\d-|glossary)|labs\/L\d\d-)/],
  ['首次小练习', /\/labs\/L01-state-machine\.html#first-exercise|\/labs\/L01-state-machine\.html#0-/],
]) {
  const results = index.search(query)
  assert.ok(results.length, `No search result for ${query}`)
  assert.match(String(results[0].id), expected, `A reader entry should lead the results for ${query}`)
  assert.ok(results.every(result => !/\/labs\/solutions\/|\/docs\/(?:validation[^/]*|p[234][^/]*-report)\.html/.test(String(result.id))), 'Historical reports and separate solutions must stay out of reader search')
  console.log(`Reader search: ${query} -> ${results[0].id}`)
}
console.log(`Built-index reader search audit passed (${fileURLToPath(new URL(indexFile, chunks))}).`)
