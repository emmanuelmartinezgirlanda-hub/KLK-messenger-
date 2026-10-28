package api

import "testing"

func TestFiltroOfensivo(t *testing.T) {
	malos := []string{"eres un PENDEJO", "hijo de puta", "hijodeputa", "p0rn gratis", "puuuuta", "Mamaguevo!", "fuck you", "f.u.c.k"}
	for _, s := range malos {
		if !isOffensive(s) {
			t.Errorf("debería bloquear %q", s)
		}
	}
	buenos := []string{"Vendo cartera de cuero", "Perra en adopción", "cono de helado", "coger la guagua",
		"Gracias por nosotros", "Pollo guisado", "Camisa polo", "Computadora", "Disputa", "La Romana", "huevos frescos"}
	for _, s := range buenos {
		if isOffensive(s) {
			t.Errorf("no debería bloquear %q", s)
		}
	}
}
