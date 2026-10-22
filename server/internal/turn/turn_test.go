package turn

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestCloudflareListAndCache(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Authorization") != "Bearer tok" || r.URL.Path != "/v1/turn/keys/kid/credentials/generate-ice-servers" {
			w.WriteHeader(401)
			return
		}
		w.Write([]byte(`{"iceServers":[{"urls":["stun:stun.cloudflare.com:3478","turn:turn.cloudflare.com:3478?transport=udp","http://x"],"username":"u","credential":"c"}]}`))
	}))
	defer srv.Close()
	c := &Cache{P: Cloudflare{KeyID: "kid", Token: "tok", BaseURL: srv.URL}}
	s, err := c.Servers(context.Background())
	if err != nil || len(s) != 1 || len(s[0].URLs) != 2 || s[0].Username != "u" {
		t.Fatalf("servers=%+v err=%v", s, err)
	}
	c.Servers(context.Background())
	if calls.Load() != 1 {
		t.Fatalf("debería usar la caché, llamadas=%d", calls.Load())
	}
}

func TestCloudflareOldObject(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"iceServers":{"urls":["turn:turn.cloudflare.com:3478"],"username":"u","credential":"c"}}`))
	}))
	defer srv.Close()
	s, err := (&Cache{P: Cloudflare{KeyID: "k", Token: "t", BaseURL: srv.URL}}).Servers(context.Background())
	if err != nil || len(s) != 1 {
		t.Fatalf("servers=%+v err=%v", s, err)
	}
}

func TestTwilio(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || u != "AC1" || p != "secret" || r.URL.Path != "/2010-04-01/Accounts/AC1/Tokens.json" {
			w.WriteHeader(401)
			return
		}
		w.WriteHeader(201)
		w.Write([]byte(`{"ice_servers":[{"url":"stun:global.stun.twilio.com:3478","urls":"stun:global.stun.twilio.com:3478"},{"urls":"turn:global.turn.twilio.com:3478?transport=udp","username":"x","credential":"y"}],"ttl":"43200"}`))
	}))
	defer srv.Close()
	s, err := (&Cache{P: Twilio{AccountSID: "AC1", AuthToken: "secret", BaseURL: srv.URL}}).Servers(context.Background())
	if err != nil || len(s) != 2 || s[1].Credential != "y" {
		t.Fatalf("servers=%+v err=%v", s, err)
	}
}

func TestNilCache(t *testing.T) {
	var c *Cache
	if s, err := c.Servers(context.Background()); s != nil || err != nil {
		t.Fatal("una caché vacía no da servidores")
	}
}
