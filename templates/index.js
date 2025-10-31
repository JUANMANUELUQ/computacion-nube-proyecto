const btnAccept = document.getElementById('btnAccept');
    const btnPublish = document.getElementById('btnPublish');
    const hostname = document.getElementById('hostname');
    const zipfile = document.getElementById('zipfile');
    const messages = document.getElementById('messages');

    btnAccept.addEventListener('click', async () => {
      const h = hostname.value.trim();
      if(!h) {
        messages.textContent = 'Por favor ingresa un nombre de host.';
        messages.style.color = '#b02a37';
        return;
      }
      // Validación simple: no espacios y mínimo 3 caracteres
      if(/\s/.test(h) || h.length < 3) {
        messages.textContent = 'Nombre de host no válido.';
        messages.style.color = '#b02a37';
        return;
      }
      try {
        const form = new FormData();
        form.append('hostname', h);
        messages.style.color = '#0b3a66';
        messages.textContent = `Preparando VM y DNS para ${h}...`;
        const res = await fetch('/prepare', { method: 'POST', body: form });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || ('HTTP '+res.status));
        messages.style.color = '#0b8a57';
        messages.textContent = `Preparación completa. IP: ${data.ip}. Ahora sube el ZIP y pulsa Publicar.`;
        setTimeout(() => {
          if (typeof window.loadDNSLogs === 'function') window.loadDNSLogs();
          if (typeof window.loadDNSDirect === 'function') window.loadDNSDirect();
        }, 500);
      } catch (e) {
        messages.style.color = '#b02a37';
        messages.textContent = 'Error en preparación: ' + e.message;
      }
    });

    btnPublish.addEventListener('click', async () => {
      if(!hostname.value.trim()) {
        messages.style.color = '#b02a37';
        messages.textContent = 'Primero ingresa el nombre de host y pulsa Aceptar.';
        return;
      }
      if(!zipfile.files || zipfile.files.length === 0) {
        messages.style.color = '#b02a37';
        messages.textContent = 'Selecciona un archivo .zip con tu contenido web.';
        return;
      }
      const file = zipfile.files[0];
      if(!file.name.toLowerCase().endsWith('.zip')) {
        messages.style.color = '#b02a37';
        messages.textContent = 'El archivo debe ser .zip';
        return;
      }
      // Llamar backend /provision
      try {
        const form = new FormData();
        form.append('hostname', hostname.value.trim());
        form.append('file', file, file.name);
        messages.style.color = '#0b3a66';
        messages.textContent = `Enviando solicitud de aprovisionamiento para ${hostname.value}...`;

        const res = await fetch('/publish', {
          method: 'POST',
          body: form
        });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const data = await res.json();
        messages.style.color = '#0b8a57';
        messages.textContent = `Sitio publicado: ${data.url}.`;
        // Actualizar registro de actividad después de publicar
        if (typeof loadAndRender === 'function') loadAndRender(true);
      } catch (err) {
        messages.style.color = '#b02a37';
        messages.textContent = 'Error enviando solicitud: ' + err.message;
      }
    });