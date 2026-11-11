package api_test

import "testing"

func TestCanales(t *testing.T) {
	e := newEnv(t)
	ana := e.register("+18095550501", 1)
	luis := e.register("+18095550502", 1)

	var c struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		Followers int    `json:"followers"`
		Following bool   `json:"following"`
		Mine      bool   `json:"mine"`
	}
	if s := e.do("POST", "/v1/channels", ana.token, map[string]string{"name": "X"}, nil); s != 400 {
		t.Fatalf("nombre corto: %d", s)
	}
	if s := e.do("POST", "/v1/channels", ana.token, map[string]string{"name": "Noticias RD", "description": "Lo último", "emoji": "🇩🇴"}, &c); s != 200 || !c.Mine || c.ID == "" {
		t.Fatalf("crear: %d %+v", s, c)
	}
	id := c.ID
	if s := e.do("POST", "/v1/channels/"+id+"/posts", luis.token, map[string]string{"body": "hola"}, nil); s != 403 {
		t.Fatalf("solo el dueño publica: %d", s)
	}
	var p struct {
		ID string `json:"id"`
	}
	if s := e.do("POST", "/v1/channels/"+id+"/posts", ana.token, map[string]string{"body": "¡Klk mi gente!"}, &p); s != 200 || p.ID == "" {
		t.Fatalf("publicar: %d", s)
	}
	if s := e.do("POST", "/v1/channels/"+id+"/posts", ana.token, map[string]any{"body": "", "image": []byte("no es foto")}, nil); s != 400 {
		t.Fatalf("foto mala: %d", s)
	}
	if s := e.do("POST", "/v1/channels/"+id+"/posts", ana.token, map[string]any{"body": "foto", "image": []byte("\xFF\xD8\xFFjpeg")}, nil); s != 200 {
		t.Fatalf("foto: %d", s)
	}
	var list struct {
		Channels []struct {
			ID       string `json:"id"`
			LastPost *struct {
				Body string `json:"body"`
			} `json:"lastPost"`
		} `json:"channels"`
	}
	if s := e.do("GET", "/v1/channels?q=noticias", luis.token, nil, &list); s != 200 || len(list.Channels) != 1 {
		t.Fatalf("buscar: %d %+v", s, list)
	}
	if s := e.do("GET", "/v1/channels?mine=1", luis.token, nil, &list); s != 200 || len(list.Channels) != 0 {
		t.Fatalf("aún no lo sigo: %+v", list)
	}
	if s := e.do("POST", "/v1/channels/"+id+"/follow", luis.token, nil, nil); s != 204 {
		t.Fatalf("seguir: %d", s)
	}
	if s := e.do("GET", "/v1/channels?mine=1", luis.token, nil, &list); s != 200 || len(list.Channels) != 1 || list.Channels[0].LastPost == nil || list.Channels[0].LastPost.Body != "foto" {
		t.Fatalf("mis canales: %+v", list)
	}
	e.do("GET", "/v1/channels/"+id, luis.token, nil, &c)
	if c.Followers != 1 || !c.Following || c.Mine {
		t.Fatalf("canal visto por Luis: %+v", c)
	}
	var posts struct {
		Posts []struct {
			ID       string `json:"id"`
			HasImage bool   `json:"hasImage"`
		} `json:"posts"`
	}
	if s := e.do("GET", "/v1/channels/"+id+"/posts", luis.token, nil, &posts); s != 200 || len(posts.Posts) != 2 || !posts.Posts[0].HasImage {
		t.Fatalf("publicaciones: %d %+v", s, posts)
	}
	var lg struct {
		LogoV int `json:"logoV"`
	}
	if s := e.do("PUT", "/v1/channels/"+id+"/logo", luis.token, map[string]any{"image": []byte("\x89PNGlogo")}, nil); s != 403 {
		t.Fatalf("solo el dueño pone logo: %d", s)
	}
	if s := e.do("PUT", "/v1/channels/"+id+"/logo", ana.token, map[string]any{"image": []byte("\x89PNGlogo")}, &lg); s != 200 || lg.LogoV != 1 {
		t.Fatalf("poner logo: %d %+v", s, lg)
	}
	var cv struct {
		LogoV int `json:"logoV"`
	}
	e.do("GET", "/v1/channels/"+id, luis.token, nil, &cv)
	if cv.LogoV != 1 {
		t.Fatalf("logoV en el canal: %+v", cv)
	}
	if s := e.do("GET", "/v1/channels/"+id+"/logo", luis.token, nil, nil); s != 200 {
		t.Fatalf("ver logo: %d", s)
	}
	if s := e.do("DELETE", "/v1/channels/"+id+"/posts/"+p.ID, ana.token, nil, nil); s != 204 {
		t.Fatalf("borrar publicación: %d", s)
	}
	if s := e.do("DELETE", "/v1/channels/"+id+"/follow", luis.token, nil, nil); s != 204 {
		t.Fatalf("dejar de seguir: %d", s)
	}
	if s := e.do("DELETE", "/v1/channels/"+id, luis.token, nil, nil); s != 403 {
		t.Fatalf("Luis no puede borrar: %d", s)
	}
	if s := e.do("DELETE", "/v1/channels/"+id, ana.token, nil, nil); s != 204 {
		t.Fatalf("borrar canal: %d", s)
	}
	if s := e.do("GET", "/v1/channels/"+id, luis.token, nil, nil); s != 404 {
		t.Fatalf("ya no existe: %d", s)
	}
}

func TestCanalOficial(t *testing.T) {
	e := newAdminEnv(t)
	dueno := e.register("+18095550701", 1)
	ya := e.register("+18095550702", 1)
	var c struct {
		ID string `json:"id"`
	}
	e.do("POST", "/v1/channels", dueno.token, map[string]string{"name": "KLK MESSENGER", "emoji": "🇩🇴"}, &c)
	e.do("POST", "/v1/channels", ya.token, map[string]string{"name": "Otro canal"}, nil)
	if s := e.do("POST", "/admin/api/channels/"+c.ID+"/official", ya.token, map[string]bool{"official": true}, nil); s != 401 {
		t.Fatalf("solo el panel: %d", s)
	}
	if s := e.do("POST", "/admin/api/channels/"+c.ID+"/official", adminTok, map[string]bool{"official": true}, nil); s != 204 {
		t.Fatalf("hacer oficial: %d", s)
	}
	nuevo := e.register("+18095550703", 1)
	for _, u := range []string{ya.token, nuevo.token} {
		var list struct {
			Channels []struct {
				ID       string `json:"id"`
				Official bool   `json:"official"`
			} `json:"channels"`
		}
		e.do("GET", "/v1/channels?mine=1", u, nil, &list)
		found := false
		for _, ch := range list.Channels {
			if ch.ID == c.ID && ch.Official {
				found = true
			}
		}
		if !found {
			t.Fatalf("debe seguir el canal oficial: %+v", list)
		}
	}
	var all struct {
		Channels []struct {
			ID string `json:"id"`
		} `json:"channels"`
	}
	e.do("GET", "/v1/channels", nuevo.token, nil, &all)
	if len(all.Channels) < 2 || all.Channels[0].ID != c.ID {
		t.Fatalf("el oficial sale primero: %+v", all)
	}
	if s := e.do("PUT", "/admin/api/channels/"+c.ID+"/logo", adminTok, map[string]any{"image": []byte("\x89PNGx")}, nil); s != 200 {
		t.Fatalf("logo desde el panel: %d", s)
	}
}
