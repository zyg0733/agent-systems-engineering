import { createServer } from 'node:http'
import { readFile, realpath } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json', '.txt': 'text/plain', '.woff2': 'font/woff2', '.woff': 'font/woff', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.ico': 'image/x-icon' }
const defaultDist = fileURLToPath(new URL('../.vitepress/dist/', import.meta.url))

export async function startPreview({ dist = defaultDist, base = process.env.SITE_BASE || '/agent-systems-engineering/', port = 4173 } = {}) {
  if (!/^\/(?:[a-zA-Z0-9_-]+\/)*$/.test(base)) throw new Error('Invalid SITE_BASE')
  const root = await realpath(dist)
  const server = createServer(async (request, response) => {
    response.setHeader('Cache-Control', 'no-store')
    response.setHeader('X-Content-Type-Options', 'nosniff')
    if (!['GET', 'HEAD'].includes(request.method)) {
      response.writeHead(405, { Allow: 'GET, HEAD' }).end()
      return
    }
    let pathname
    try { pathname = new URL(request.url, 'http://127.0.0.1').pathname } catch { response.writeHead(400).end(); return }
    if (base !== '/' && pathname === base.slice(0, -1)) {
      response.writeHead(302, { Location: base }).end()
      return
    }
    if (!pathname.startsWith(base)) { response.writeHead(404).end(); return }
    let relative
    try { relative = decodeURIComponent(pathname.slice(base.length)) } catch { response.writeHead(400).end(); return }
    if (relative.includes('\\') || relative.includes('\0') || relative.split('/').includes('..')) {
      response.writeHead(403).end()
      return
    }
    relative = !relative || relative.endsWith('/') ? relative + 'index.html' : path.extname(relative) ? relative : relative + '.html'
    try {
      const target = await realpath(path.join(root, relative))
      if (!target.startsWith(root + path.sep)) { response.writeHead(403).end(); return }
      const bytes = await readFile(target)
      const type = types[path.extname(target)] || 'application/octet-stream'
      response.writeHead(200, { 'Content-Type': type + (/^(text\/|image\/svg|application\/json)/.test(type) ? '; charset=utf-8' : ''), 'Content-Length': bytes.length })
      response.end(request.method === 'HEAD' ? undefined : bytes)
    } catch {
      response.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' })
      let fallback = Buffer.from('Page not found')
      try {
        const target = await realpath(path.join(root, '404.html'))
        if (target.startsWith(root + path.sep)) fallback = await readFile(target)
      } catch { /* A missing or external fallback is replaced by fixed text. */ }
      response.end(request.method === 'HEAD' ? undefined : fallback)
    }
  })
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '127.0.0.1', resolve)
  })
  if (server.address().address !== '127.0.0.1') {
    server.close()
    throw new Error('Preview must listen only on IPv4 loopback')
  }
  return server
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const index = process.argv.indexOf('--port')
  const port = index === -1 ? 4173 : Number(process.argv[index + 1])
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Use a port from 1024 to 65535')
  const server = await startPreview({ port })
  console.log(`Reading preview: http://127.0.0.1:${server.address().port}${process.env.SITE_BASE || '/agent-systems-engineering/'}`)
}
