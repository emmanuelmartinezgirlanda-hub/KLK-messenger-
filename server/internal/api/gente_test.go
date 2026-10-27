package api_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

type genteAuthor struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Photo string `json:"photo"`
}

type gentePost struct {
	ID        string      `json:"id"`
	Author    genteAuthor `json:"author"`
	Country   string      `json:"country"`
	Text      string      `json:"text"`
	Photos    []string    `json:"photos"`
	CreatedAt time.Time   `json:"createdAt"`
	Likes     int         `json:"likes"`
	Comments  int         `json:"comments"`
	Liked     bool        `json:"liked"`
}

type genteComment struct {
	ID     string      `json:"id"`
	Author genteAuthor `json:"author"`
	Text   string      `json:"text"`
}

func (e *env) uploadGente(tok string, body []byte) (int, string) {
	e.t.Helper()
	req, _ := http.NewRequest("POST", e.srv.URL+"/v1/gente/images", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	var out struct {
		ID string `json:"id"`
	}
	json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out.ID
}

func TestGente(t *testing.T) {
	e := newAdminEnv(t)
	ana := e.register("+18095550201", 1)
	luis := e.register("+353870000202", 2)
	png := append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 64)...)

	// Perfil con foto
	_, foto := e.uploadGente(ana.token, png)
	// Sin aceptar las normas no se puede publicar
	e.do("PUT", "/v1/gente/me", ana.token, map[string]any{"name": "Ana"}, nil)
	if s := e.do("POST", "/v1/gente/posts", ana.token, map[string]any{"text": "hola"}, nil); s != 403 {
		t.Fatalf("publicar sin normas: %d", s)
	}
	var me genteAuthor
	if s := e.do("PUT", "/v1/gente/me", ana.token, map[string]any{"name": "  Ana   Pérez ", "photo": foto, "rules": true}, &me); s != 200 ||
		me.Name != "Ana Pérez" || me.Photo != foto {
		t.Fatalf("perfil: %d %+v", s, me)
	}
	if s := e.do("PUT", "/v1/gente/me", luis.token, map[string]any{"name": "Luis", "photo": foto}, nil); s != 400 {
		t.Fatalf("foto ajena en el perfil: %d", s)
	}
	e.do("PUT", "/v1/gente/me", luis.token, map[string]any{"name": "Luis", "rules": true}, nil)
	// Cambiar el nombre después no borra la aceptación de las normas
	e.do("PUT", "/v1/gente/me", ana.token, map[string]any{"name": "Ana Pérez", "photo": foto}, nil)

	// Publicar: validaciones
	bad := []map[string]any{
		{"text": "   "},
		{"text": strings.Repeat("a", 2001)},
		{"text": "hola", "country": "rd"},
		{"text": "hola", "photos": []string{"no-existe"}},
		{"text": "hola", "photos": []string{foto, foto}},
	}
	for i, b := range bad {
		if s := e.do("POST", "/v1/gente/posts", ana.token, b, nil); s != 400 {
			t.Fatalf("publicación mala %d: %d", i, s)
		}
	}
	_, f1 := e.uploadGente(ana.token, png)
	if s := e.do("POST", "/v1/gente/posts", luis.token, map[string]any{"text": "x", "photos": []string{f1}}, nil); s != 400 {
		t.Fatalf("publicar foto ajena: %d", s)
	}
	var p1 gentePost
	if s := e.do("POST", "/v1/gente/posts", ana.token, map[string]any{"text": " ¡Klk mi gente! ", "photos": []string{f1}, "country": "DO"}, &p1); s != 201 ||
		p1.Text != "¡Klk mi gente!" || p1.Author.Name != "Ana Pérez" || len(p1.Photos) != 1 {
		t.Fatalf("publicar: %d %+v", s, p1)
	}
	time.Sleep(5 * time.Millisecond)
	var p2 gentePost
	e.do("POST", "/v1/gente/posts", luis.token, map[string]any{"text": "Saludos desde Dublín", "country": "IE"}, &p2)

	// El muro: lo más nuevo primero, filtro por país y por persona
	var feed struct {
		Posts []gentePost `json:"posts"`
	}
	get := func(q string) []gentePost {
		feed.Posts = nil
		if s := e.do("GET", "/v1/gente/feed"+q, luis.token, nil, &feed); s != 200 {
			t.Fatalf("muro %q: %d", q, s)
		}
		return feed.Posts
	}
	if l := get(""); len(l) != 2 || l[0].ID != p2.ID {
		t.Fatalf("muro: %+v", l)
	}
	if l := get("?country=DO"); len(l) != 1 || l[0].ID != p1.ID {
		t.Fatalf("por país: %+v", l)
	}
	if l := get("?author=" + luis.accountID); len(l) != 1 || l[0].ID != p2.ID {
		t.Fatalf("por persona: %+v", l)
	}
	if l := get("?before=" + p2.CreatedAt.Format(time.RFC3339Nano)); len(l) != 1 || l[0].ID != p1.ID {
		t.Fatalf("más antiguas: %+v", l)
	}

	// Me gusta
	var like struct {
		Likes int  `json:"likes"`
		Liked bool `json:"liked"`
	}
	e.do("PUT", "/v1/gente/posts/"+p1.ID+"/like", luis.token, nil, &like)
	e.do("PUT", "/v1/gente/posts/"+p1.ID+"/like", luis.token, nil, &like) // dos veces cuenta una
	if like.Likes != 1 || !like.Liked {
		t.Fatalf("me gusta: %+v", like)
	}
	if l := get("?country=DO"); !l[0].Liked || l[0].Likes != 1 {
		t.Fatalf("me gusta en el muro: %+v", l[0])
	}

	// Comentarios
	var c genteComment
	if s := e.do("POST", "/v1/gente/posts/"+p1.ID+"/comments", luis.token, map[string]string{"text": "¡Klk!"}, &c); s != 201 ||
		c.Author.Name != "Luis" {
		t.Fatalf("comentar: %d %+v", s, c)
	}
	var cs struct {
		Comments []genteComment `json:"comments"`
	}
	e.do("GET", "/v1/gente/posts/"+p1.ID+"/comments", ana.token, nil, &cs)
	if len(cs.Comments) != 1 || get("?country=DO")[0].Comments != 1 {
		t.Fatalf("comentarios: %+v", cs)
	}
	// La dueña de la publicación puede borrar comentarios en ella; otro no
	var c2 genteComment
	e.do("POST", "/v1/gente/posts/"+p2.ID+"/comments", ana.token, map[string]string{"text": "Wepa"}, &c2)
	if s := e.do("DELETE", "/v1/gente/comments/"+c.ID, ana.token, nil, nil); s != 204 {
		t.Fatalf("borrar comentario en mi publicación: %d", s)
	}

	// Denunciar y borrar
	if s := e.do("POST", "/v1/gente/posts/"+p1.ID+"/report", luis.token, map[string]string{"reason": "spam"}, nil); s != 204 {
		t.Fatalf("denunciar: %d", s)
	}
	var reps struct {
		Reports []struct {
			Messages []string `json:"messages"`
		} `json:"reports"`
	}
	e.do("GET", "/admin/api/reports", adminTok, nil, &reps)
	if len(reps.Reports) != 1 || !strings.Contains(reps.Reports[0].Messages[0], p1.ID) {
		t.Fatalf("denuncia en el panel: %+v", reps)
	}
	if s := e.do("DELETE", "/v1/gente/posts/"+p1.ID, luis.token, nil, nil); s != 403 {
		t.Fatalf("borrar ajena: %d", s)
	}
	if s := e.do("DELETE", "/admin/api/gente/posts/"+p1.ID, adminTok, nil, nil); s != 204 {
		t.Fatalf("el dueño borra: %d", s)
	}
	if l := get(""); len(l) != 1 {
		t.Fatalf("tras borrar: %+v", l)
	}
	if res, _ := http.Get(e.srv.URL + "/v1/gente/img/" + f1); res.StatusCode != 404 {
		t.Fatalf("la foto de la publicación borrada sigue: %d", res.StatusCode)
	}
	if res, _ := http.Get(e.srv.URL + "/v1/gente/img/" + foto); res.StatusCode != 200 {
		t.Fatalf("la foto de perfil se borró: %d", res.StatusCode)
	}

	// Una cuenta bloqueada desaparece del muro
	if s := e.do("POST", "/admin/api/accounts/"+luis.accountID+"/ban", adminTok, map[string]string{"reason": "spam"}, nil); s != 204 {
		t.Fatalf("bloquear: %d", s)
	}
	feed.Posts = nil
	e.do("GET", "/v1/gente/feed", ana.token, nil, &feed)
	if len(feed.Posts) != 0 {
		t.Fatalf("bloqueado sigue en el muro: %+v", feed.Posts)
	}
}

func TestGenteBlocks(t *testing.T) {
	e := newAdminEnv(t)
	ana := e.register("+18095550301", 1)
	luis := e.register("+18095550302", 2)
	for _, u := range []user{ana, luis} {
		e.do("PUT", "/v1/gente/me", u.token, map[string]any{"name": "X", "rules": true}, nil)
	}
	var pa, pl gentePost
	e.do("POST", "/v1/gente/posts", ana.token, map[string]any{"text": "de Ana"}, &pa)
	e.do("POST", "/v1/gente/posts", luis.token, map[string]any{"text": "de Luis"}, &pl)
	var c genteComment
	e.do("POST", "/v1/gente/posts/"+pl.ID+"/comments", ana.token, map[string]string{"text": "hola Luis"}, &c)

	if s := e.do("PUT", "/v1/gente/blocks/"+ana.accountID, ana.token, nil, nil); s != 400 {
		t.Fatalf("bloquearse a sí misma: %d", s)
	}
	if s := e.do("PUT", "/v1/gente/blocks/no-existe", ana.token, nil, nil); s != 404 {
		t.Fatalf("bloquear cuenta inexistente: %d", s)
	}
	// Ana bloquea a Luis
	if s := e.do("PUT", "/v1/gente/blocks/"+luis.accountID, ana.token, nil, nil); s != 204 {
		t.Fatalf("bloquear: %d", s)
	}
	var feed struct {
		Posts []gentePost `json:"posts"`
	}
	for _, u := range []user{ana, luis} { // ninguno ve lo del otro
		feed.Posts = nil
		e.do("GET", "/v1/gente/feed", u.token, nil, &feed)
		if len(feed.Posts) != 1 || feed.Posts[0].Author.ID != u.accountID {
			t.Fatalf("muro con bloqueo: %+v", feed.Posts)
		}
	}
	feed.Posts = nil
	e.do("GET", "/v1/gente/feed?author="+ana.accountID, luis.token, nil, &feed)
	if len(feed.Posts) != 0 {
		t.Fatalf("Luis ve el perfil de Ana: %+v", feed.Posts)
	}
	if s := e.do("POST", "/v1/gente/posts/"+pa.ID+"/comments", luis.token, map[string]string{"text": "x"}, nil); s != 404 {
		t.Fatalf("Luis comenta a quien le bloqueó: %d", s)
	}
	if s := e.do("PUT", "/v1/gente/posts/"+pa.ID+"/like", luis.token, nil, nil); s != 404 {
		t.Fatalf("Luis da me gusta a quien le bloqueó: %d", s)
	}
	var list struct {
		Blocked []genteAuthor `json:"blocked"`
	}
	e.do("GET", "/v1/gente/blocks", ana.token, nil, &list)
	if len(list.Blocked) != 1 || list.Blocked[0].ID != luis.accountID {
		t.Fatalf("lista de bloqueados: %+v", list)
	}
	// Desbloquear: vuelve todo
	if s := e.do("DELETE", "/v1/gente/blocks/"+luis.accountID, ana.token, nil, nil); s != 204 {
		t.Fatalf("desbloquear: %d", s)
	}
	feed.Posts = nil
	e.do("GET", "/v1/gente/feed", luis.token, nil, &feed)
	if len(feed.Posts) != 2 {
		t.Fatalf("tras desbloquear: %+v", feed.Posts)
	}
	var cs struct {
		Comments []genteComment `json:"comments"`
	}
	e.do("GET", "/v1/gente/posts/"+pl.ID+"/comments", luis.token, nil, &cs)
	if len(cs.Comments) != 1 {
		t.Fatalf("comentarios tras desbloquear: %+v", cs)
	}
}

func TestGenteSale(t *testing.T) {
	e := newAdminEnv(t)
	ana := e.register("+18095550401", 1)
	luis := e.register("+18095550402", 2)
	for _, u := range []user{ana, luis} {
		e.do("PUT", "/v1/gente/me", u.token, map[string]any{"name": "X", "rules": true}, nil)
	}
	bad := []map[string]any{
		{"text": "", "photos": []string{}, "sale": map[string]any{"price": 10, "currency": "RD$"}},
		{"text": "Nevera", "sale": map[string]any{"price": 0, "currency": "RD$"}},
		{"text": "Nevera", "sale": map[string]any{"price": 20000000, "currency": "RD$"}},
		{"text": "Nevera", "sale": map[string]any{"price": 10, "currency": "BTC"}},
	}
	for i, b := range bad {
		if s := e.do("POST", "/v1/gente/posts", ana.token, b, nil); s != 400 {
			t.Fatalf("venta mala %d: %d", i, s)
		}
	}
	var venta gentePostSale
	if s := e.do("POST", "/v1/gente/posts", ana.token, map[string]any{"text": "Vendo nevera", "sale": map[string]any{"price": 150.555, "currency": "€"}}, &venta); s != 201 ||
		!venta.Sale || venta.Price != 150.56 || venta.Currency != "€" || venta.Sold {
		t.Fatalf("publicar venta: %d %+v", s, venta)
	}
	var normal gentePostSale
	e.do("POST", "/v1/gente/posts", ana.token, map[string]any{"text": "¡Klk!"}, &normal)

	var feed struct {
		Posts []gentePostSale `json:"posts"`
	}
	e.do("GET", "/v1/gente/feed?sale=1", luis.token, nil, &feed)
	if len(feed.Posts) != 1 || feed.Posts[0].ID != venta.ID {
		t.Fatalf("filtro en venta: %+v", feed.Posts)
	}
	// Solo quien vende marca «Vendido», y solo en ventas
	if s := e.do("PUT", "/v1/gente/posts/"+venta.ID+"/sold", luis.token, nil, nil); s != 403 {
		t.Fatalf("otro marca vendido: %d", s)
	}
	if s := e.do("PUT", "/v1/gente/posts/"+normal.ID+"/sold", ana.token, nil, nil); s != 400 {
		t.Fatalf("vendido en algo que no es venta: %d", s)
	}
	if s := e.do("PUT", "/v1/gente/posts/"+venta.ID+"/sold", ana.token, nil, nil); s != 204 {
		t.Fatalf("marcar vendido: %d", s)
	}
	feed.Posts = nil
	e.do("GET", "/v1/gente/feed?sale=1", luis.token, nil, &feed)
	if len(feed.Posts) != 1 || !feed.Posts[0].Sold {
		t.Fatalf("vendido: %+v", feed.Posts)
	}
	e.do("DELETE", "/v1/gente/posts/"+venta.ID+"/sold", ana.token, nil, nil)
	feed.Posts = nil
	e.do("GET", "/v1/gente/feed?sale=1", luis.token, nil, &feed)
	if feed.Posts[0].Sold {
		t.Fatal("no se quitó «vendido»")
	}
}

type gentePostSale struct {
	gentePost
	Sale     bool    `json:"sale"`
	Price    float64 `json:"price"`
	Currency string  `json:"currency"`
	Sold     bool    `json:"sold"`
}
