package api

import (
	"net/http"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// Filtro de contenido ofensivo (norma 1.2 de Apple): lo público (Mi Gente,
// Negocios, nombres y @usuario) no puede llevar insultos graves, odio ni
// contenido sexual explícito. Los chats privados van cifrados y no se filtran
// aquí; para eso están denunciar y bloquear.

// Palabras completas (ya sin acentos y en minúsculas).
var offensiveWords = map[string]bool{}

// Trozos que bastan aunque vayan pegados a otras letras (sin falsos positivos
// razonables en español o inglés).
var offensiveParts = []string{
	"hijodeputa", "hijueputa", "hijoeputa", "malparido", "maricon", "nigger", "faggot",
	"motherfucker", "fuck", "porno", "pornhub", "xvideos", "onlyfans", "pedofil",
	"putamadre", "mamaguevo", "mamaguebo", "mamahuevo", "singao", "chupamela", "comemierda",
}

func init() {
	for _, w := range []string{
		// Español (incluido dominicano). Sin palabras con otro uso normal
		// (cono, perra, cuero, coger, huevo…) para no bloquear un «Vendo».
		"puta", "puto", "putas", "putos", "pendejo", "pendeja", "cabron", "cabrona",
		"mierda", "culo", "verga", "polla", "pinga", "chocha", "huevon", "huevona",
		"estupido", "estupida", "idiota", "imbecil", "bastardo", "bastarda", "negrata", "sudaca",
		"travelo", "bollera", "tortillera", "muerete", "suicidate", "nazi", "desgraciado", "desgraciada",
		"follar", "chingar", "chingada", "singa", "singar", "nigga", "retrasado",
		// Inglés
		"shit", "bitch", "bitches", "slut", "whore", "cunt", "asshole", "bastard", "pussy",
		"kys", "rape", "porn", "nudes", "retard",
	} {
		offensiveWords[foldText(w)] = true
	}
	for i, p := range offensiveParts {
		offensiveParts[i] = foldText(p)
	}
}

// foldText: minúsculas, sin acentos, números típicos cambiados por letras
// (p0rn → porn) y letras repetidas reducidas (puuuta → puta).
func foldText(s string) string {
	s = norm.NFD.String(strings.ToLower(s))
	var b strings.Builder
	var last rune
	for _, r := range s {
		if unicode.Is(unicode.Mn, r) {
			continue // acentos
		}
		switch r {
		case '0':
			r = 'o'
		case '1', '!':
			r = 'i'
		case '3':
			r = 'e'
		case '4', '@':
			r = 'a'
		case '5', '$':
			r = 's'
		case '7':
			r = 't'
		}
		if !unicode.IsLetter(r) {
			r = ' '
		}
		if r == last && r != ' ' {
			continue
		}
		last = r
		b.WriteRune(r)
	}
	return b.String()
}

// isOffensive dice si el texto tiene palabras que no se permiten en lo público.
func isOffensive(texts ...string) bool {
	for _, t := range texts {
		f := foldText(t)
		words := strings.Fields(f)
		// «f.u.c.k» o «p u t a»: une las letras sueltas seguidas.
		var run strings.Builder
		for _, w := range append(append([]string{}, words...), "--") {
			if len([]rune(w)) == 1 {
				run.WriteString(w)
				continue
			}
			if run.Len() > 1 {
				words = append(words, run.String())
			}
			run.Reset()
		}
		for _, w := range words {
			if offensiveWords[w] {
				return true
			}
		}
		for _, w := range words {
			for _, p := range offensiveParts {
				if strings.Contains(w, p) {
					return true
				}
			}
		}
	}
	return false
}

// rejectOffensive responde 400 si el texto no se permite. Devuelve true si lo rechazó.
func rejectOffensive(w http.ResponseWriter, texts ...string) bool {
	if !isOffensive(texts...) {
		return false
	}
	writeErr(w, http.StatusBadRequest, "offensive",
		"ese texto tiene palabras que no se permiten en KLK. Revisa las Normas de KLK.")
	return true
}
