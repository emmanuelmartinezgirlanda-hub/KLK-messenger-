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
