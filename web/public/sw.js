// Service worker de l'application de collecte : met la coquille de l'application en cache pour qu'elle s'ouvre hors réseau.
// Les appels /api ne sont JAMAIS interceptés : les données passent par la file IndexedDB de l'application, pas par ce cache.
const VERSION = 'sfd-collecte-v3'
const COQUILLE = ['/', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png', '/favicon.svg']

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(VERSION).then(async (c) => {
      await c.addAll(COQUILLE)
      // JS/CSS hachés cités par la page : sans eux, la coquille en cache s'afficherait vide
      const html = await (await c.match('/'))?.text() ?? ''
      const assets = [...html.matchAll(/(?:src|href)="(\/assets\/[^"]+)"/g)].map((m) => m[1])
      await c.addAll(assets)
    }).then(() => self.skipWaiting()),
  )
})

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (e) => {
  const req = e.request
  const url = new URL(req.url)
  if (req.method !== 'GET' || url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return
  if (req.mode === 'navigate') {
    // page : réseau d'abord (version à jour), sinon la coquille mise en cache (application à page unique)
    e.respondWith(
      fetch(req)
        .then((res) => {
          const copie = res.clone()
          void caches.open(VERSION).then((c) => c.put('/', copie))
          return res
        })
        .catch(() => caches.match('/', { ignoreVary: true }).then((r) => r || Response.error())),
    )
    return
  }
  // ressources (JS/CSS hachés, icônes) : cache d'abord, complété à la volée
  e.respondWith(
    caches.match(req, { ignoreVary: true }).then(
      (hit) =>
        hit ||
        fetch(req).then((res) => {
          if (res.ok) {
            const copie = res.clone()
            void caches.open(VERSION).then((c) => c.put(req, copie))
          }
          return res
        }),
    ),
  )
})
