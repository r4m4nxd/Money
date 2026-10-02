// Offline shell for the gym: serve the app from cache when there's no signal; data calls (Supabase) always go to the network.
const C='atb-v2';const SHELL=['./','index.html','seed.json','manifest.webmanifest','icons/crest-640.jpg','icons/apple-touch-icon.png','icons/favicon-32.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==C).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||(u.hostname.endsWith('supabase.co')&&!u.pathname.includes('/storage/v1/object/public/')))return;
  // images (card art, icons, flags, star photos): straight from the phone's cache, fetched once
  if(u.origin===location.origin&&/^\/(cards|icons)\//.test(u.pathname)||u.pathname.includes('/storage/v1/object/public/stars/')&&!u.pathname.endsWith('.json')){e.respondWith(caches.open(C).then(c=>c.match(e.request).then(hit=>hit||fetch(e.request).then(r=>{if(r.ok)c.put(e.request,r.clone());return r}))));return}
  e.respondWith(fetch(e.request).then(r=>{if(r.ok&&(u.origin===location.origin||/cdnjs|jsdelivr|fonts\.g/.test(u.hostname))){const cp=r.clone();caches.open(C).then(c=>c.put(e.request,cp))}return r}).catch(()=>caches.match(e.request).then(r=>r||caches.match('index.html'))))});
