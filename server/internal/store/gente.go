package store

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// KLK Mi Gente: el muro público dentro de KLK. Las publicaciones, me gusta y
// comentarios son públicos para la gente de KLK (no van cifrados como los chats).

// GenteAuthor es como sale alguien en Mi Gente (nombre y foto que puso él mismo).
type GenteAuthor struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Photo string `json:"photo"` // id de la foto en gente_images ('' = sin foto)
}

// GenteProfile es el nombre y la foto públicos de una cuenta en Mi Gente.
type GenteProfile struct {
	AccountID string
	Name      string
	Photo     string
	UpdatedAt time.Time
}

type GentePost struct {
	ID        string      `json:"id"`
	Author    GenteAuthor `json:"author"`
	Country   string      `json:"country"`
	Text      string      `json:"text"`
	Photos    []string    `json:"photos"`
	CreatedAt time.Time   `json:"createdAt"`
	Likes     int         `json:"likes"`
	Comments  int         `json:"comments"`
	Liked     bool        `json:"liked"` // ¿le di me gusta yo?
}

type GenteComment struct {
	ID        string      `json:"id"`
	PostID    string      `json:"postId"`
	Author    GenteAuthor `json:"author"`
	Text      string      `json:"text"`
	CreatedAt time.Time   `json:"createdAt"`
}

// GenteQuery filtra el muro (campos vacíos = sin filtro).
type GenteQuery struct {
	Viewer  string    // quién mira (para saber si le dio me gusta)
	Country string    // "DO", "IE"…
	Author  string    // solo las de esta cuenta
	Before  time.Time // para pedir más (las anteriores a esta hora)
	Limit   int
}

func (q GenteQuery) limit() int {
	if q.Limit <= 0 || q.Limit > 50 {
		return 20
	}
	return q.Limit
}

func (q GenteQuery) before() time.Time {
	if q.Before.IsZero() {
		return time.Now().Add(time.Hour)
	}
	return q.Before
}

type GenteStore interface {
	PutGenteProfile(ctx context.Context, p GenteProfile) error
	AddGentePost(ctx context.Context, p GentePost) error
	// GetGentePost devuelve ErrNotFound si no existe o su autor está bloqueado.
	GetGentePost(ctx context.Context, id, viewer string) (GentePost, error)
	ListGentePosts(ctx context.Context, q GenteQuery) ([]GentePost, error)
	DeleteGentePost(ctx context.Context, id string) error
	// SetGenteLike pone o quita mi me gusta y devuelve cuántos tiene la publicación.
	SetGenteLike(ctx context.Context, post, account string, on bool) (int, error)
	AddGenteComment(ctx context.Context, c GenteComment) error
	GetGenteComment(ctx context.Context, id string) (GenteComment, error)
	ListGenteComments(ctx context.Context, post string, limit int) ([]GenteComment, error)
	DeleteGenteComment(ctx context.Context, id string) error
	PutGenteImage(ctx context.Context, img BusinessImage) error
	GetGenteImage(ctx context.Context, id string) (BusinessImage, error)
	// PurgeGenteImages borra las fotos subidas antes de [before] que no usa
	// ninguna publicación ni ningún perfil (subidas y nunca publicadas).
	PurgeGenteImages(ctx context.Context, before time.Time) (int, error)
}

// ---------- Memoria ----------

type memGente struct {
	profiles map[string]GenteProfile
	posts    map[string]GentePost // sin contadores; se calculan al leer
	likes    map[string]map[string]bool
	comments map[string]GenteComment
	images   map[string]BusinessImage
}

func (m *Memory) gente() *memGente {
	if m.gent == nil {
		m.gent = &memGente{
			profiles: map[string]GenteProfile{},
			posts:    map[string]GentePost{},
			likes:    map[string]map[string]bool{},
			comments: map[string]GenteComment{},
			images:   map[string]BusinessImage{},
		}
	}
	return m.gent
}

func (m *Memory) genteAuthorLocked(id string) GenteAuthor {
	p := m.gente().profiles[id]
	return GenteAuthor{ID: id, Name: p.Name, Photo: p.Photo}
}

func (m *Memory) gentePostLocked(p GentePost, viewer string) GentePost {
	g := m.gente()
	p.Author = m.genteAuthorLocked(p.Author.ID)
	p.Likes = len(g.likes[p.ID])
	p.Liked = viewer != "" && g.likes[p.ID][viewer]
	p.Comments = 0
	for _, c := range g.comments {
		if c.PostID == p.ID && !m.bannedLocked(c.Author.ID) {
			p.Comments++
		}
	}
	if p.Photos == nil {
		p.Photos = []string{}
	}
	return p
}

func (m *Memory) PutGenteProfile(_ context.Context, p GenteProfile) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[p.AccountID]; !ok {
		return ErrNotFound
	}
	m.gente().profiles[p.AccountID] = p
	return nil
}

func (m *Memory) AddGentePost(_ context.Context, p GentePost) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[p.Author.ID]; !ok {
		return ErrNotFound
	}
	p.Photos = append([]string{}, p.Photos...)
	m.gente().posts[p.ID] = p
	return nil
}

func (m *Memory) GetGentePost(_ context.Context, id, viewer string) (GentePost, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.gente().posts[id]
	if !ok || m.bannedLocked(p.Author.ID) {
		return GentePost{}, ErrNotFound
	}
	if _, ok := m.accounts[p.Author.ID]; !ok {
		return GentePost{}, ErrNotFound
	}
	return m.gentePostLocked(p, viewer), nil
}

func (m *Memory) ListGentePosts(_ context.Context, q GenteQuery) ([]GentePost, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	before := q.before()
	out := []GentePost{}
	for _, p := range m.gente().posts {
		if _, ok := m.accounts[p.Author.ID]; !ok || m.bannedLocked(p.Author.ID) {
			continue
		}
		if (q.Country != "" && p.Country != q.Country) || (q.Author != "" && p.Author.ID != q.Author) ||
			!p.CreatedAt.Before(before) {
			continue
		}
		out = append(out, m.gentePostLocked(p, q.Viewer))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	if len(out) > q.limit() {
		out = out[:q.limit()]
	}
	return out, nil
}

func (m *Memory) DeleteGentePost(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.gente()
	p, ok := g.posts[id]
	if !ok {
		return ErrNotFound
	}
	delete(g.posts, id)
	delete(g.likes, id)
	for cid, c := range g.comments {
		if c.PostID == id {
			delete(g.comments, cid)
		}
	}
	for _, ph := range p.Photos {
		delete(g.images, ph)
	}
	return nil
}

func (m *Memory) SetGenteLike(_ context.Context, post, acc string, on bool) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.gente()
	if _, ok := g.posts[post]; !ok {
		return 0, ErrNotFound
	}
	if on {
		if g.likes[post] == nil {
			g.likes[post] = map[string]bool{}
		}
		g.likes[post][acc] = true
	} else {
		delete(g.likes[post], acc)
	}
	return len(g.likes[post]), nil
}

func (m *Memory) AddGenteComment(_ context.Context, c GenteComment) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.gente()
	if _, ok := g.posts[c.PostID]; !ok {
		return ErrNotFound
	}
	if _, ok := m.accounts[c.Author.ID]; !ok {
		return ErrNotFound
	}
	g.comments[c.ID] = c
	return nil
}

func (m *Memory) GetGenteComment(_ context.Context, id string) (GenteComment, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.gente().comments[id]
	if !ok {
		return GenteComment{}, ErrNotFound
	}
	c.Author = m.genteAuthorLocked(c.Author.ID)
	return c, nil
}

func (m *Memory) ListGenteComments(_ context.Context, post string, limit int) ([]GenteComment, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []GenteComment{}
	for _, c := range m.gente().comments {
		if c.PostID == post && !m.bannedLocked(c.Author.ID) {
			c.Author = m.genteAuthorLocked(c.Author.ID)
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	if limit > 0 && len(out) > limit {
		out = out[len(out)-limit:]
	}
	return out, nil
}

func (m *Memory) DeleteGenteComment(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.gente().comments[id]; !ok {
		return ErrNotFound
	}
	delete(m.gente().comments, id)
	return nil
}

func (m *Memory) PutGenteImage(_ context.Context, img BusinessImage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[img.Owner]; !ok {
		return ErrNotFound
	}
	img.Data = append([]byte(nil), img.Data...)
	if img.CreatedAt.IsZero() {
		img.CreatedAt = time.Now()
	}
	m.gente().images[img.ID] = img
	return nil
}

func (m *Memory) GetGenteImage(_ context.Context, id string) (BusinessImage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	img, ok := m.gente().images[id]
	if !ok {
		return BusinessImage{}, ErrNotFound
	}
	if _, ok := m.accounts[img.Owner]; !ok || m.bannedLocked(img.Owner) {
		return BusinessImage{}, ErrNotFound
	}
	return img, nil
}

func (m *Memory) PurgeGenteImages(_ context.Context, before time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.gente()
	used := map[string]bool{}
	for _, p := range g.posts {
		for _, ph := range p.Photos {
			used[ph] = true
		}
	}
	for _, p := range g.profiles {
		used[p.Photo] = true
	}
	n := 0
	for id, img := range g.images {
		if !used[id] && img.CreatedAt.Before(before) {
			delete(g.images, id)
			n++
		}
	}
	return n, nil
}

// deleteGenteLocked borra todo lo de una cuenta (al borrar la cuenta).
func (m *Memory) deleteGenteLocked(acc string) {
	if m.gent == nil {
		return
	}
	g := m.gent
	delete(g.profiles, acc)
	for id, p := range g.posts {
		if p.Author.ID == acc {
			delete(g.posts, id)
			delete(g.likes, id)
		}
	}
	for _, likes := range g.likes {
		delete(likes, acc)
	}
	for id, c := range g.comments {
		if _, ok := g.posts[c.PostID]; !ok || c.Author.ID == acc {
			delete(g.comments, id)
		}
	}
	for id, img := range g.images {
		if img.Owner == acc {
			delete(g.images, id)
		}
	}
}

// ---------- Postgres ----------

func isUUID(s string) bool { _, err := uuid.Parse(s); return err == nil }

func (p *Postgres) PutGenteProfile(ctx context.Context, g GenteProfile) error {
	if !isUUID(g.AccountID) {
		return ErrNotFound
	}
	_, err := p.pool.Exec(ctx, `
		INSERT INTO gente_profiles (account_id, name, photo, updated_at) VALUES ($1, $2, $3, $4)
		ON CONFLICT (account_id) DO UPDATE SET name = EXCLUDED.name, photo = EXCLUDED.photo, updated_at = EXCLUDED.updated_at`,
		g.AccountID, g.Name, g.Photo, g.UpdatedAt)
	return err
}

func (p *Postgres) AddGentePost(ctx context.Context, g GentePost) error {
	if !isUUID(g.Author.ID) {
		return ErrNotFound
	}
	photos, _ := json.Marshal(append([]string{}, g.Photos...))
	_, err := p.pool.Exec(ctx, `
		INSERT INTO gente_posts (id, author, country, body, photos, created_at) VALUES ($1, $2, $3, $4, $5, $6)`,
		g.ID, g.Author.ID, g.Country, g.Text, photos, g.CreatedAt)
	return err
}

const gentePostCols = `
	p.id::text, p.author::text, coalesce(g.name, ''), coalesce(g.photo, ''), p.country, p.body, p.photos, p.created_at,
	(SELECT count(*) FROM gente_likes l WHERE l.post = p.id),
	(SELECT count(*) FROM gente_comments c JOIN accounts ca ON ca.id = c.author
	  WHERE c.post = p.id AND ca.banned_at IS NULL),
	EXISTS (SELECT 1 FROM gente_likes l WHERE l.post = p.id AND l.account::text = $1)`

const gentePostFrom = `
	FROM gente_posts p JOIN accounts a ON a.id = p.author
	LEFT JOIN gente_profiles g ON g.account_id = p.author
	WHERE a.banned_at IS NULL`

func scanGentePost(row pgx.Row) (GentePost, error) {
	var g GentePost
	var photos []byte
	err := row.Scan(&g.ID, &g.Author.ID, &g.Author.Name, &g.Author.Photo, &g.Country, &g.Text, &photos,
		&g.CreatedAt, &g.Likes, &g.Comments, &g.Liked)
	g.Photos = []string{}
	if err == nil {
		json.Unmarshal(photos, &g.Photos)
	}
	return g, err
}

func (p *Postgres) GetGentePost(ctx context.Context, id, viewer string) (GentePost, error) {
	if !isUUID(id) {
		return GentePost{}, ErrNotFound
	}
	g, err := scanGentePost(p.pool.QueryRow(ctx, `SELECT `+gentePostCols+gentePostFrom+` AND p.id = $2`, viewer, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return GentePost{}, ErrNotFound
	}
	return g, err
}

func (p *Postgres) ListGentePosts(ctx context.Context, q GenteQuery) ([]GentePost, error) {
	if q.Author != "" && !isUUID(q.Author) {
		return []GentePost{}, nil
	}
	rows, err := p.pool.Query(ctx, `SELECT `+gentePostCols+gentePostFrom+`
		  AND ($2 = '' OR p.country = $2)
		  AND ($3 = '' OR p.author::text = $3)
		  AND p.created_at < $4
		ORDER BY p.created_at DESC LIMIT $5`, q.Viewer, q.Country, q.Author, q.before(), q.limit())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []GentePost{}
	for rows.Next() {
		g, err := scanGentePost(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

func (p *Postgres) DeleteGentePost(ctx context.Context, id string) error {
	if !isUUID(id) {
		return ErrNotFound
	}
	var photos []byte
	err := p.pool.QueryRow(ctx, `DELETE FROM gente_posts WHERE id = $1 RETURNING photos`, id).Scan(&photos)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	var ids []string
	json.Unmarshal(photos, &ids)
	if len(ids) > 0 {
		_, err = p.pool.Exec(ctx, `DELETE FROM gente_images WHERE id::text = ANY($1)`, ids)
	}
	return err
}

func (p *Postgres) SetGenteLike(ctx context.Context, post, acc string, on bool) (int, error) {
	if !isUUID(post) || !isUUID(acc) {
		return 0, ErrNotFound
	}
	var err error
	if on {
		_, err = p.pool.Exec(ctx, `
			INSERT INTO gente_likes (post, account) SELECT $1, $2 WHERE EXISTS (SELECT 1 FROM gente_posts WHERE id = $1)
			ON CONFLICT DO NOTHING`, post, acc)
	} else {
		_, err = p.pool.Exec(ctx, `DELETE FROM gente_likes WHERE post = $1 AND account = $2`, post, acc)
	}
	if err != nil {
		return 0, err
	}
	var n int
	var exists bool
	err = p.pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM gente_posts WHERE id = $1), (SELECT count(*) FROM gente_likes WHERE post = $1)`,
		post).Scan(&exists, &n)
	if err == nil && !exists {
		return 0, ErrNotFound
	}
	return n, err
}

func (p *Postgres) AddGenteComment(ctx context.Context, c GenteComment) error {
	if !isUUID(c.PostID) || !isUUID(c.Author.ID) {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `
		INSERT INTO gente_comments (id, post, author, body, created_at)
		SELECT $1, $2, $3, $4, $5 WHERE EXISTS (SELECT 1 FROM gente_posts WHERE id = $2)`,
		c.ID, c.PostID, c.Author.ID, c.Text, c.CreatedAt)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

const genteCommentSelect = `
	SELECT c.id::text, c.post::text, c.author::text, coalesce(g.name, ''), coalesce(g.photo, ''), c.body, c.created_at
	FROM gente_comments c JOIN accounts a ON a.id = c.author
	LEFT JOIN gente_profiles g ON g.account_id = c.author`

func scanGenteComment(row pgx.Row) (GenteComment, error) {
	var c GenteComment
	err := row.Scan(&c.ID, &c.PostID, &c.Author.ID, &c.Author.Name, &c.Author.Photo, &c.Text, &c.CreatedAt)
	return c, err
}

func (p *Postgres) GetGenteComment(ctx context.Context, id string) (GenteComment, error) {
	if !isUUID(id) {
		return GenteComment{}, ErrNotFound
	}
	c, err := scanGenteComment(p.pool.QueryRow(ctx, genteCommentSelect+` WHERE c.id = $1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return GenteComment{}, ErrNotFound
	}
	return c, err
}

func (p *Postgres) ListGenteComments(ctx context.Context, post string, limit int) ([]GenteComment, error) {
	if !isUUID(post) {
		return []GenteComment{}, nil
	}
	if limit <= 0 {
		limit = 200
	}
	rows, err := p.pool.Query(ctx, `SELECT * FROM (`+genteCommentSelect+`
		WHERE c.post = $1 AND a.banned_at IS NULL ORDER BY c.created_at DESC LIMIT $2) x ORDER BY 7`, post, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []GenteComment{}
	for rows.Next() {
		c, err := scanGenteComment(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (p *Postgres) DeleteGenteComment(ctx context.Context, id string) error {
	if !isUUID(id) {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `DELETE FROM gente_comments WHERE id = $1`, id)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

func (p *Postgres) PutGenteImage(ctx context.Context, img BusinessImage) error {
	if !isUUID(img.Owner) {
		return ErrNotFound
	}
	_, err := p.pool.Exec(ctx, `INSERT INTO gente_images (id, owner, mime, data) VALUES ($1, $2, $3, $4)`,
		img.ID, img.Owner, img.Mime, img.Data)
	return err
}

func (p *Postgres) GetGenteImage(ctx context.Context, id string) (BusinessImage, error) {
	if !isUUID(id) {
		return BusinessImage{}, ErrNotFound
	}
	var img BusinessImage
	err := p.pool.QueryRow(ctx, `
		SELECT i.id::text, i.owner::text, i.mime, i.data, i.created_at
		FROM gente_images i JOIN accounts a ON a.id = i.owner
		WHERE i.id = $1 AND a.banned_at IS NULL`, id).
		Scan(&img.ID, &img.Owner, &img.Mime, &img.Data, &img.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return BusinessImage{}, ErrNotFound
	}
	return img, err
}

func (p *Postgres) PurgeGenteImages(ctx context.Context, before time.Time) (int, error) {
	tag, err := p.pool.Exec(ctx, `
		DELETE FROM gente_images i WHERE i.created_at < $1
		  AND NOT EXISTS (SELECT 1 FROM gente_posts p WHERE p.photos ? i.id::text)
		  AND NOT EXISTS (SELECT 1 FROM gente_profiles g WHERE g.photo = i.id::text)`, before)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}
