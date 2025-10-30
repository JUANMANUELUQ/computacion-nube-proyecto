Sitios de prueba (para empaquetar y publicar)

- Ubicación: `sites/`
- Carpetas incluidas:
  - `sites/sample/` sitio base de verificación de despliegue
  - `sites/paisajes/` galería simple con imágenes de paisajes
  - `sites/negocios/` landing de negocios
  - `sites/blog/` plantilla mínima de blog

Cómo comprimir (Windows):
1) Entra a la carpeta del sitio, p. ej. `sites/paisajes/`.
2) Selecciona los archivos (index.html, style.css, health.txt, etc.).
3) Crea un ZIP con esos archivos en el nivel superior del ZIP (no incluyas la carpeta).
4) En la UI: Aceptar (prepare) con el hostname, y luego Publicar adjuntando el ZIP.

Nota: El `index.html` y archivos deben estar en la raíz del ZIP. `deploy_web.sh` descomprime en `/var/www/<hostname>`.
