const btnAccept = document.getElementById('btnAccept');
    const btnPublish = document.getElementById('btnPublish');
    const hostname = document.getElementById('hostname');
    const zipfile = document.getElementById('zipfile');
    const messages = document.getElementById('messages');

    btnAccept.addEventListener('click', () => {
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
      messages.style.color = '#0b8a57';
      messages.textContent = `Host "${h}" aceptado. Listo para publicar.`;
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

        const res = await fetch('/provision', {
          method: 'POST',
          body: form
        });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const data = await res.json();
        messages.style.color = '#0b8a57';
        messages.textContent = `Solicitud aceptada. ID: ${data.id}. Seguimiento en el registro.`;
      } catch (err) {
        messages.style.color = '#b02a37';
        messages.textContent = 'Error enviando solicitud: ' + err.message;
      }
    });