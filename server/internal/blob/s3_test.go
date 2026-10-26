package blob

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

// Ejemplo oficial de AWS (GET Object con Range) de la documentación de SigV4.
func TestSignAWSExample(t *testing.T) {
	req, _ := http.NewRequest("GET", "https://examplebucket.s3.amazonaws.com/test.txt", nil)
	req.Header.Set("Range", "bytes=0-9")
	tm, _ := time.Parse("20060102T150405Z", "20130524T000000Z")
	Sign(req, nil, "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "us-east-1", "s3", tm)
	want := "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
	if got := req.Header.Get("Authorization"); !strings.HasSuffix(got, "Signature="+want) {
		t.Fatalf("firma: %s", got)
	}
}

func TestS3RoundTrip(t *testing.T) {
	var mu sync.Mutex
	objs := map[string][]byte{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential=ak/") {
			w.WriteHeader(403)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		key := strings.TrimPrefix(r.URL.Path, "/bkt/")
		switch {
		case r.Method == "PUT":
			b, _ := io.ReadAll(r.Body)
			objs[key] = b
		case r.Method == "GET" && r.URL.Path == "/bkt":
			io.WriteString(w, `<ListBucketResult><Contents><Key>att/a</Key><LastModified>2026-01-01T00:00:00.000Z</LastModified></Contents><IsTruncated>false</IsTruncated></ListBucketResult>`)
		case r.Method == "GET":
			b, ok := objs[key]
			if !ok {
				w.WriteHeader(404)
				return
			}
			w.Write(b)
		case r.Method == "DELETE":
			delete(objs, key)
			w.WriteHeader(204)
		}
	}))
	defer srv.Close()
	s := &S3{Endpoint: srv.URL, Bucket: "bkt", AccessKey: "ak", SecretKey: "sk"}
	ctx := context.Background()
	if err := s.Put(ctx, "att/a", []byte("hola")); err != nil {
		t.Fatal(err)
	}
	b, err := s.Get(ctx, "att/a")
	if err != nil || string(b) != "hola" {
		t.Fatalf("get: %q %v", b, err)
	}
	if _, err := s.Get(ctx, "att/zz"); err != ErrNotFound {
		t.Fatalf("404: %v", err)
	}
	l, err := s.List(ctx, "att/")
	if err != nil || len(l) != 1 || l[0].Key != "att/a" || l[0].LastModified.Year() != 2026 {
		t.Fatalf("list: %+v %v", l, err)
	}
	if err := s.Delete(ctx, "att/a"); err != nil {
		t.Fatal(err)
	}
}

func TestStoreFallback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "PUT" {
			return
		}
		w.WriteHeader(404)
	}))
	defer srv.Close()
	mem := store.NewMemory()
	b := &Store{Store: mem, S3: &S3{Endpoint: srv.URL, Bucket: "b", AccessKey: "ak", SecretKey: "sk"}}
	if err := b.PutAttachment(context.Background(), "x", "no-existe", []byte("a")); err == nil {
		t.Fatal("cuenta inexistente aceptada")
	}
	if _, err := b.GetAttachment(context.Background(), "nada"); err != store.ErrNotFound {
		t.Fatalf("fallback: %v", err)
	}
}

// R2 falso en memoria (con fecha de cada objeto para la limpieza).
func fakeR2(t *testing.T) (*S3, map[string][]byte, map[string]time.Time) {
	var mu sync.Mutex
	objs, when := map[string][]byte{}, map[string]time.Time{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		key := strings.TrimPrefix(r.URL.Path, "/bkt/")
		switch {
		case r.Method == "PUT":
			b, _ := io.ReadAll(r.Body)
			objs[key], when[key] = b, time.Now()
		case r.Method == "GET" && r.URL.Path == "/bkt":
			p := r.URL.Query().Get("prefix")
			io.WriteString(w, "<ListBucketResult>")
			for k := range objs {
				if strings.HasPrefix(k, p) {
					io.WriteString(w, "<Contents><Key>"+k+"</Key><LastModified>"+when[k].UTC().Format(time.RFC3339)+"</LastModified></Contents>")
				}
			}
			io.WriteString(w, "<IsTruncated>false</IsTruncated></ListBucketResult>")
		case r.Method == "GET":
			b, ok := objs[key]
			if !ok {
				w.WriteHeader(404)
				return
			}
			w.Write(b)
		case r.Method == "DELETE":
			delete(objs, key)
			w.WriteHeader(204)
		}
	}))
	t.Cleanup(srv.Close)
	return &S3{Endpoint: srv.URL, Bucket: "bkt", AccessKey: "ak", SecretKey: "sk"}, objs, when
}

func TestImagesInR2(t *testing.T) {
	ctx := context.Background()
	s3, objs, when := fakeR2(t)
	mem := store.NewMemory()
	b := &Store{Store: mem, S3: s3}
	dev, err := mem.RegisterPrimary(ctx, store.RegisterParams{Phone: "+18095550001", TokenHash: []byte("t")})
	if err != nil {
		t.Fatal(err)
	}
	owner := dev.AccountID
	png := []byte("\x89PNG\r\n\x1a\nfoto")
	for _, c := range []struct {
		prefix string
		put    func(context.Context, store.BusinessImage) error
		get    func(context.Context, string) (store.BusinessImage, error)
	}{{"biz/", b.PutBusinessImage, b.GetBusinessImage}, {"gente/", b.PutGenteImage, b.GetGenteImage}} {
		id := "0f8fad5b-d9cb-469f-a165-70867728950" + string(c.prefix[0])
		if err := c.put(ctx, store.BusinessImage{ID: id, Owner: owner, Mime: "image/png", Data: png}); err != nil {
			t.Fatal(err)
		}
		// Los bytes van a R2; en la base de datos solo la ficha
		if string(objs[c.prefix+id]) != string(png) {
			t.Fatalf("%s no está en R2", c.prefix)
		}
		img, err := c.get(ctx, id)
		if err != nil || string(img.Data) != string(png) || img.Mime != "image/png" {
			t.Fatalf("%s leer: %v %q", c.prefix, err, img.Data)
		}
		if err := c.put(ctx, store.BusinessImage{ID: "x", Owner: "nadie", Mime: "image/png", Data: png}); err == nil {
			t.Fatal("cuenta inexistente aceptada")
		}
	}

	// Una foto que ya no usa nadie se borra de R2 (pero no si es reciente)
	bizID := "0f8fad5b-d9cb-469f-a165-70867728950b"
	if _, err := mem.PruneBusinessImages(ctx, owner, nil, time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if n := b.sweepImages(ctx, time.Now()); n != 0 || objs["biz/"+bizID] == nil {
		t.Fatalf("borró una foto recién subida (%d)", n)
	}
	when["biz/"+bizID] = time.Now().Add(-2 * time.Hour)
	when["gente/0f8fad5b-d9cb-469f-a165-70867728950g"] = time.Now().Add(-2 * time.Hour)
	if n := b.sweepImages(ctx, time.Now()); n != 1 || objs["biz/"+bizID] != nil {
		t.Fatalf("limpieza: %d", n)
	}
	if objs["gente/0f8fad5b-d9cb-469f-a165-70867728950g"] == nil {
		t.Fatal("borró una foto que sí se usa")
	}
}
