/* -------- CONFIG ------- */
const JSON_URL = '/instances';
const DEFAULT_ZONE = 'grid.lab';
const POLL_INTERVAL_MS = 3000;

/* -------- RENDER ------- */
function formatDate(iso) {
  if(!iso) return '';
  const d = new Date(iso);
  return d.toLocaleString(); // puedes customizar
}

function canonicalUrl(item) {
  // Preferimos item.url si ya es completa, pero si no, la construimos
  if (item && typeof item.url === 'string' && item.url.startsWith('http')) return item.url;
  const host = (item && item.host) ? item.host : '';
  const fqdn = host.indexOf('.') === -1 && host ? `${host}.${DEFAULT_ZONE}` : host;
  return fqdn ? `http://${fqdn}` : '';
}

function createRow(item) {
  const tr = document.createElement('tr');
  tr.className = 'activity-row';

  // link
  const tdLink = document.createElement('td');
  tdLink.className = 'activity-cell';
  const a = document.createElement('a');
  const link = canonicalUrl(item);
  a.href = link || '#';
  a.textContent = link || (item.url || '');
  a.className = 'activity-link';
  a.target = '_blank';
  tdLink.appendChild(a);

  // ip
  const tdIp = document.createElement('td');
  tdIp.className = 'activity-cell';
  tdIp.textContent = item.ip;

  // host
  const tdHost = document.createElement('td');
  tdHost.className = 'activity-cell';
  tdHost.textContent = item.host;

  // created_at
  const tdCreated = document.createElement('td');
  tdCreated.className = 'activity-cell';
  tdCreated.textContent = formatDate(item.created_at);

  // actions
  const tdAction = document.createElement('td');
  tdAction.className = 'activity-cell';
  const btn = document.createElement('button');
  btn.className = 'btn-delete';
  btn.textContent = 'Eliminar';
  btn.onclick = (ev) => {
    ev.preventDefault();
    if (!confirm('¿Eliminar esta instancia?')) return;
    // Llamada DELETE a API (si existe). Si no, simular actualizando localmente.
    fetch(`/api/instances/${encodeURIComponent(item.id)}`, { method: 'DELETE' })
      .then(r => {
        if (r.ok) {
          // forzar recarga inmediata
          loadAndRender(true);
        } else {
          // si backend no implementado: intentar actualizar local cache forcely
          console.warn('DELETE failed, reloading file');
          loadAndRender(true);
        }
      })
      .catch(err => {
        console.warn('No hay backend DELETE, actualizando vista localmente', err);
        loadAndRender(true);
      });
  };
  tdAction.appendChild(btn);

  tr.appendChild(tdLink);
  tr.appendChild(tdIp);
  tr.appendChild(tdHost);
  tr.appendChild(tdCreated);
  tr.appendChild(tdAction);

  return tr;
}

/* -------- DIFF & RENDER LIST ------- */
let lastDataJson = null;

function renderList(data) {
  const tbody = document.getElementById('activityBody');
  if(!tbody) return;

  // Si no hay cambios exactos en texto, evitamos re-render total (pequeño diff).
  const newJson = JSON.stringify(data);
  if (newJson === lastDataJson) return; // no hay cambios

  lastDataJson = newJson;
  // limpiar y render
  tbody.innerHTML = '';
  data.forEach((item, idx) => {
    const row = createRow(item);
    // Alternar fila sombreada similar al mockup
    if(idx % 2 === 1) row.style.background = '#e9e9e9';
    tbody.appendChild(row);
  });
}

/* -------- LOAD JSON ------- */
async function loadInstances() {
  try {
    const res = await fetch(JSON_URL, {cache: 'no-store'});
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const data = await res.json();
    if (!Array.isArray(data)) throw new Error('Formato JSON inválido, se esperaba array.');
    return data;
  } catch (err) {
    console.error('Error cargando JSON:', err);
    return null;
  }
}

let pollTimer = null;
async function loadAndRender(force=false) {
  const data = await loadInstances();
  if (!data) return;
  renderList(data);
  if (force && pollTimer) {
    // refrescar inmediatamente
    clearInterval(pollTimer);
    pollTimer = setInterval(loadAndRender, POLL_INTERVAL_MS);
  }
}

/* -------- START POLLING ------- */
document.addEventListener('DOMContentLoaded', () => {
  loadAndRender();
  pollTimer = setInterval(loadAndRender, POLL_INTERVAL_MS);
});
