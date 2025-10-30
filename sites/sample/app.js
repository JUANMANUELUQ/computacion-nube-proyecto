(function() {
  const el = document.getElementById('hostInfo');
  try {
    const host = window.location.host;
    const href = window.location.href;
    if (el) el.textContent = `Host: ${host} — URL: ${href}`;
    const rootLink = document.getElementById('rootLink');
    if (rootLink) rootLink.href = '/';
  } catch (e) {
    if (el) el.textContent = 'Información no disponible';
  }
})();


