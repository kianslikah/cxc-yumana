// Service Worker para Yumana Apartados/Créditos
// Estrategia: Network-First (siempre intenta cargar versión nueva primero)
// Cache solo como fallback si no hay internet

const CACHE_VERSION = 'yumana-apartados-v5-2026-05-18';
const CACHE_FILES = [
  'Apartados_Yumana_App.html',
  'manifest_apartados.json'
];

self.addEventListener('install', event => {
  console.log('[SW] Install', CACHE_VERSION);
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_VERSION).then(cache => cache.addAll(CACHE_FILES).catch(e => console.warn('[SW] Cache fail', e)))
  );
});

self.addEventListener('activate', event => {
  console.log('[SW] Activate', CACHE_VERSION);
  event.waitUntil(
    caches.keys().then(keys => {
      return Promise.all(
        keys.filter(k => k !== CACHE_VERSION).map(k => {
          console.log('[SW] Borrando cache viejo:', k);
          return caches.delete(k);
        })
      );
    }).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  if (event.request.url.indexOf('supabase.co') !== -1) return;
  if (event.request.url.indexOf('wa.me') !== -1) return;

  event.respondWith(
    fetch(event.request).then(response => {
      if (response.ok && event.request.method === 'GET') {
        const responseClone = response.clone();
        caches.open(CACHE_VERSION).then(cache => {
          cache.put(event.request, responseClone).catch(() => {});
        });
      }
      return response;
    }).catch(() => {
      return caches.match(event.request).then(cached => {
        if (cached) {
          console.log('[SW] Sirviendo desde cache (offline):', event.request.url);
          return cached;
        }
        return new Response('Sin conexión', {status: 503, statusText: 'Offline'});
      });
    })
  );
});

self.addEventListener('message', event => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
  if (event.data && event.data.type === 'CLEAR_CACHE') {
    caches.keys().then(keys => Promise.all(keys.map(k => caches.delete(k))));
  }
});
