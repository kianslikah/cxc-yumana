// Service worker de Personal: SOLO recibe los avisos de vales (web push) y abre Personal al tocarlos.
// Su alcance es solo personal.html (lo registra personal.html con scope './personal.html' cuando un admin
// activa los avisos): no se cruza con el de Créditos (sw_apartados.js, en la raíz) ni con ninguna otra app.
// No tiene manejador de "fetch": no guarda nada en caché ni intercepta la página.
self.addEventListener('install', function(){ self.skipWaiting(); });
self.addEventListener('activate', function(e){ e.waitUntil(self.clients.claim()); });

self.addEventListener('push', function(e){
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Mercantil Yumana', {
    body: d.body || '',
    icon: 'iconos/yumana-192.png',
    badge: 'iconos/yumana-192.png',
    tag: d.tag || undefined,
    data: { url: d.url || 'personal.html' }
  }));
});

self.addEventListener('notificationclick', function(e){
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || 'personal.html', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(ventanas){
    for (var i = 0; i < ventanas.length; i++) {
      var w = ventanas[i];
      if (w.url.indexOf('personal.html') >= 0 && 'focus' in w) {
        return w.focus().then(function(f){ return f && f.navigate ? f.navigate(url) : f; });
      }
    }
    return self.clients.openWindow(url);
  }));
});
