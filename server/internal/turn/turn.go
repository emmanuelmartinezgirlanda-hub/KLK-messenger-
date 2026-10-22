// Package turn consigue credenciales temporales de un servidor TURN para las
// llamadas. TURN hace de «puente» cuando los dos móviles no pueden conectarse
// directamente (datos móviles, wifi de empresa, internet malo). El audio y el
// vídeo siguen cifrados de punta a punta (DTLS-SRTP): el puente no los ve.
package turn

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// ICEServer es lo que necesita WebRTC (RTCIceServer).
type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// Provider da una lista de servidores con credenciales válidas durante ttl.
type Provider interface {
	fetch(ctx context.Context, ttl time.Duration) ([]ICEServer, error)
}

// Cache pide credenciales nuevas como mucho una vez por hora y las comparte.
type Cache struct {
	P   Provider
	TTL time.Duration // validez de cada credencial (por defecto 12 h)

	mu      sync.Mutex
	servers []ICEServer
	until   time.Time
}

// Servers devuelve servidores con credenciales que valen al menos unas horas.
func (c *Cache) Servers(ctx context.Context) ([]ICEServer, error) {
	if c == nil || c.P == nil {
		return nil, nil
	}
	ttl := c.TTL
	if ttl <= 0 {
		ttl = 12 * time.Hour
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Now().Before(c.until) {
		return c.servers, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	s, err := c.P.fetch(ctx, ttl)
	if err != nil {
		if len(c.servers) > 0 && time.Now().Before(c.until.Add(ttl/2)) {
			return c.servers, nil // aún sirven las anteriores
		}
		return nil, err
	}
	c.servers = s
	// Se renuevan bastante antes de caducar: una llamada puede durar horas.
	c.until = time.Now().Add(min(time.Hour, ttl/4))
	return s, nil
}

var httpClient = &http.Client{Timeout: 10 * time.Second}

// Cloudflare: https://developers.cloudflare.com/realtime/turn/
type Cloudflare struct {
	KeyID, Token string
	BaseURL      string // para pruebas
}

func (cf Cloudflare) fetch(ctx context.Context, ttl time.Duration) ([]ICEServer, error) {
	base := cf.BaseURL
	if base == "" {
		base = "https://rtc.live.cloudflare.com"
	}
	body, _ := json.Marshal(map[string]int{"ttl": int(ttl.Seconds())})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		base+"/v1/turn/keys/"+url.PathEscape(cf.KeyID)+"/credentials/generate-ice-servers", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+cf.Token)
	req.Header.Set("Content-Type", "application/json")
	var out struct {
		ICEServers json.RawMessage `json:"iceServers"`
	}
	if err := do(req, &out); err != nil {
		return nil, fmt.Errorf("cloudflare turn: %w", err)
	}
	var list []ICEServer
	if err := json.Unmarshal(out.ICEServers, &list); err != nil {
		var one ICEServer // versión vieja de la API: un solo objeto
		if err := json.Unmarshal(out.ICEServers, &one); err != nil {
			return nil, fmt.Errorf("cloudflare turn: respuesta rara: %w", err)
		}
		list = []ICEServer{one}
	}
	return clean(list), nil
}

// Twilio Network Traversal: https://www.twilio.com/docs/stun-turn
type Twilio struct {
	AccountSID, AuthToken string
	BaseURL               string // para pruebas
}

func (t Twilio) fetch(ctx context.Context, ttl time.Duration) ([]ICEServer, error) {
	base := t.BaseURL
	if base == "" {
		base = "https://api.twilio.com"
	}
	form := url.Values{"Ttl": {fmt.Sprint(int(ttl.Seconds()))}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		base+"/2010-04-01/Accounts/"+url.PathEscape(t.AccountSID)+"/Tokens.json", strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth(t.AccountSID, t.AuthToken)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var out struct {
		ICEServers []struct {
			URL        string `json:"url"`
			URLs       string `json:"urls"`
			Username   string `json:"username"`
			Credential string `json:"credential"`
		} `json:"ice_servers"`
	}
	if err := do(req, &out); err != nil {
		return nil, fmt.Errorf("twilio turn: %w", err)
	}
	var list []ICEServer
	for _, s := range out.ICEServers {
		u := s.URLs
		if u == "" {
			u = s.URL
		}
		list = append(list, ICEServer{URLs: []string{u}, Username: s.Username, Credential: s.Credential})
	}
	return clean(list), nil
}

func do(req *http.Request, out any) error {
	res, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("HTTP %d", res.StatusCode)
	}
	return json.NewDecoder(res.Body).Decode(out)
}

// clean quita entradas vacías y las URLs que no son stun/turn.
func clean(in []ICEServer) []ICEServer {
	var out []ICEServer
	for _, s := range in {
		var urls []string
		for _, u := range s.URLs {
			if strings.HasPrefix(u, "stun:") || strings.HasPrefix(u, "turn:") || strings.HasPrefix(u, "turns:") {
				urls = append(urls, u)
			}
		}
		if len(urls) > 0 {
			s.URLs = urls
			out = append(out, s)
		}
	}
	return out
}

// ErrNone: no hay ningún servidor TURN configurado.
var ErrNone = errors.New("sin servidor TURN")
