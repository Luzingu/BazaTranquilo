// A app mudou-se da raiz para /app/. Quem a abriu antes pode ter este
// "service worker" instalado na raiz: desliga-se e limpa o que guardou.
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (ks) { return Promise.all(ks.map(function (k) { return caches.delete(k); })); })
      .then(function () { return self.registration.unregister(); })
  );
});
