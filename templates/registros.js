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
    // Llamada DELETE al backend
    fetch(`/destroy/${encodeURIComponent(item.id)}`, { method: 'DELETE' })
      .then(r => {
        if (r.ok) {
          loadAndRender(true);
          loadDNSLogs();
          if (typeof loadDNSDirect === 'function') loadDNSDirect();
        } else {
          console.warn('DELETE failed, reloading file');
          loadAndRender(true);
          loadDNSLogs();
          if (typeof loadDNSDirect === 'function') loadDNSDirect();
        }
      })
      .catch(err => {
        console.warn('No hay backend DELETE, actualizando vista localmente', err);
        loadAndRender(true);
        loadDNSLogs();
        if (typeof loadDNSDirect === 'function') loadDNSDirect();
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

/* -------- DNS LOGS ------- */
function formatTimestamp(iso) {
  if(!iso) return '';
  const d = new Date(iso);
  const hours = String(d.getHours()).padStart(2, '0');
  const minutes = String(d.getMinutes()).padStart(2, '0');
  const seconds = String(d.getSeconds()).padStart(2, '0');
  return `${d.toLocaleDateString()} ${hours}:${minutes}:${seconds}`;
}

function renderDNSLogs(logs) {
  const container = document.getElementById('dnsLogsBody');
  if(!container) return;

  if (!logs || logs.length === 0) {
    container.innerHTML = '<div style="color:#666;text-align:center;">No hay logs DNS registrados.</div>';
    return;
  }

  container.innerHTML = '';
  logs.forEach((log) => {
    const div = document.createElement('div');
    div.style.marginBottom = '6px';
    div.style.paddingBottom = '6px';
    div.style.borderBottom = '1px solid #e9e9e9';
    
    const actionColor = log.action === 'ADD' ? '#0b8a57' : '#d11a2a';
    const actionText = log.action === 'ADD' ? 'AGREGADO' : 'ELIMINADO';
    
    div.innerHTML = `
      <span style="color:${actionColor};font-weight:bold;">[${actionText}]</span>
      <span style="color:#333;">${log.fqdn}</span>
      <span style="color:#666;">→</span>
      <span style="color:#1a73e8;">${log.ip}</span>
      <span style="color:#999;margin-left:12px;font-size:0.8em;">${formatTimestamp(log.timestamp)}</span>
    `;
    
    container.appendChild(div);
  });
}

// Función global para cargar logs DNS (disponible para index.js)
async function loadDNSLogs() {
  try {
    const res = await fetch('/dns-logs', {cache: 'no-store'});
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const data = await res.json();
    if (!Array.isArray(data)) throw new Error('Formato JSON inválido.');
    renderDNSLogs(data);
  } catch (err) {
    console.error('Error cargando logs DNS:', err);
    const container = document.getElementById('dnsLogsBody');
    if(container) {
      container.innerHTML = '<div style="color:#d11a2a;text-align:center;">Error cargando logs DNS.</div>';
    }
  }
}

// Hacer la función disponible globalmente (window.loadDNSLogs)
if (typeof window !== 'undefined') {
  window.loadDNSLogs = loadDNSLogs;
}

let dnsLogsTimer = null;

/* -------- START POLLING ------- */
document.addEventListener('DOMContentLoaded', () => {
  loadAndRender();
  pollTimer = setInterval(loadAndRender, POLL_INTERVAL_MS);
  
  // Cargar logs DNS inicialmente y actualizar cada 2 segundos
  loadDNSLogs();
  dnsLogsTimer = setInterval(loadDNSLogs, 2000);
  // Cargar estado DNS directo y actualizar cada 3 segundos
  loadDNSDirect();
  setInterval(loadDNSDirect, 3000);
});

/* -------- DNS DIRECT (desde archivo de zona en la VM) -------- */
function renderDNSDirect(records) {
  const container = document.getElementById('dnsDirectBody');
  if(!container) return;
  if (!Array.isArray(records) || records.length === 0) {
    container.innerHTML = '<div style="color:#666;text-align:center;">Sin registros A en zona.</div>';
    return;
  }
  container.innerHTML = '';
  records.forEach((r) => {
    const div = document.createElement('div');
    div.style.marginBottom = '4px';
    div.textContent = `${r.fqdn} → ${r.ip}`;
    container.appendChild(div);
  });
}

async function loadDNSDirect() {
  try {
    const res = await fetch('/dns-direct', { cache: 'no-store' });
    const data = await res.json();
    if (!res.ok || data.error) {
      throw new Error(data.error || 'Error HTTP ' + res.status);
    }
    renderDNSDirect(data);
  } catch (err) {
    console.error('Error leyendo DNS directo:', err);
    const c = document.getElementById('dnsDirectBody');
    if (c) {
      let msg = err.message || 'Error leyendo zona en DNS.';
      // Convertir saltos de línea en <br> para mejor visualización
      msg = msg.replace(/\n/g, '<br>');
      c.innerHTML = `<div style="color:#d11a2a;text-align:left;padding:15px;background:#fff3cd;border:1px solid #ffc107;border-radius:4px;font-size:0.9em;line-height:1.5;">${msg}</div>`;
    }
  }
}
