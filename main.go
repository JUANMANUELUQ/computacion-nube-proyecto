package main

import (
	"fmt"
	"net/http"
)

func main() {
	// Servir archivos estáticos (HTML, CSS, JS)
	fs := http.FileServer(http.Dir("./templates"))
	http.Handle("/", fs)

	// Servir la carpeta `services` en /services/ para exponer hosts.json y otros recursos
	servicesFs := http.FileServer(http.Dir("./services"))
	http.Handle("/services/", http.StripPrefix("/services/", servicesFs))

	fmt.Println("Servidor web en http://localhost:8080 (serving ./templates at / and ./services at /services/)")
	err := http.ListenAndServe(":8080", nil)
	if err != nil {
		fmt.Println("Error al iniciar el servidor:", err)
	}
}
