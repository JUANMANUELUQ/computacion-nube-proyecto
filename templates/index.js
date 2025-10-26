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

    btnPublish.addEventListener('click', () => {
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
      // Simulación de subida / despliegue
      messages.style.color = '#0b8a57';
      messages.textContent = `Subiendo "${file.name}" y desplegando en ${hostname.value} ... (simulado)`;
      setTimeout(() => {
        messages.textContent = `¡Publicado! Accede a: http://${hostname.value}/`;
      }, 1200);
    });