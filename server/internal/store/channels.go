package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Channel es un canal público: su dueño publica y los seguidores leen.
type Channel struct {
	ID          string     `json:"id"`
	OwnerID     string     `json:"-"`
	Name        string     `json:"name"`
	Description string     `json:"description"`
	Emoji       string     `json:"emoji"`
	LogoV       int        `json:"logoV"` // 0 = sin logo (sale el emoji)
	Official    bool       `json:"official,omitempty"`
	CreatedAt   time.Time  `json:"createdAt"`
	Followers   int        `json:"followers"`
	Following   bool       `json:"following"`
	Mine        bool       `json:"mine"`
	LastPost    *ChanPost  `json:"lastPost,omitempty"`
	LastAt      *time.Time `json:"-"`
}

// ChanPost es una publicación de un canal.
type ChanPost struct {
	ID        string    `json:"id"`
	ChannelID string    `json:"channelId"`
	Body      string    `json:"body"`
	HasImage  bool      `json:"hasImage"`
	Image     []byte    `json:"-"`
	CreatedAt time.Time `json:"createdAt"`
}

// ChannelStore guarda los canales, sus seguidores y sus publicaciones.
type ChannelStore interface {
	CreateChannel(ctx context.Context, c Channel) (Channel, error)
	UpdateChannel(ctx context.Context, c Channel) error
	DeleteChannel(ctx context.Context, id string) error
	// Channel devuelve un canal visto por [viewer] (seguidores, si lo sigo…).
	Channel(ctx context.Context, id, viewer string) (Channel, error)
	// Channels busca canales por nombre ([q] vacío = los más seguidos).
	Channels(ctx context.Context, q, viewer string, limit int) ([]Channel, error)
	// MyChannels: los que sigo y los míos, con la última publicación.
	MyChannels(ctx context.Context, viewer string) ([]Channel, error)
	CountOwnedChannels(ctx context.Context, owner string) (int, error)
	FollowChannel(ctx context.Context, id, acc string, follow bool) error
	AddChanPost(ctx context.Context, p ChanPost) (ChanPost, error)
	DeleteChanPost(ctx context.Context, channelID, postID string) error
	// ChanPosts devuelve las publicaciones más nuevas antes de [before] (cero = ahora).
	ChanPosts(ctx context.Context, channelID string, before time.Time, limit int) ([]ChanPost, error)
	ChanPostImage(ctx context.Context, channelID, postID string) ([]byte, error)
	// SetChannelLogo pone (o quita, con nil) el logo del canal.
	SetChannelLogo(ctx context.Context, id string, img []byte) (int, error)
	ChannelLogo(ctx context.Context, id string) ([]byte, error)
	// SetChannelOfficial marca (o desmarca) un canal como oficial de KLK.
	SetChannelOfficial(ctx context.Context, id string, official bool) error
	// FollowChannelAll hace que todas las cuentas sigan el canal.
	FollowChannelAll(ctx context.Context, id string) error
	// OfficialChannels: ids de los canales oficiales.
	OfficialChannels(ctx context.Context) ([]string, error)
}

// ---------- Memoria ----------

type memChannels struct {
	chans     map[string]Channel
	followers map[string]map[string]bool // canal -> cuentas
	posts     map[string][]ChanPost      // canal -> publicaciones (viejas primero)
	logos     map[string][]byte
}

func (m *Memory) ch() *memChannels {
	if m.channels == nil {
		m.channels = &memChannels{chans: map[string]Channel{}, followers: map[string]map[string]bool{}, posts: map[string][]ChanPost{}, logos: map[string][]byte{}}
	}
	return m.channels
}

// viewLocked completa los datos que dependen de quién mira.
func (m *Memory) chanViewLocked(c Channel, viewer string) Channel {
	cs := m.ch()
	n := 0
	for acc := range cs.followers[c.ID] {
		if _, ok := m.accounts[acc]; ok {
			n++
		}
	}
	c.Followers = n
	c.Following = cs.followers[c.ID][viewer]
	c.Mine = c.OwnerID == viewer
	if ps := cs.posts[c.ID]; len(ps) > 0 {
		last := ps[len(ps)-1]
		last.Image = nil
		c.LastPost = &last
		c.LastAt = &last.CreatedAt
	}
	return c
}

func (m *Memory) chanAliveLocked(c Channel) bool {
	_, ok := m.accounts[c.OwnerID]
	return ok
}

func (m *Memory) CreateChannel(_ context.Context, c Channel) (Channel, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.accounts[c.OwnerID]; !ok {
		return Channel{}, ErrNotFound
	}
	c.ID = uuid.NewString()
	c.CreatedAt = time.Now()
	m.ch().chans[c.ID] = c
	return m.chanViewLocked(c, c.OwnerID), nil
}

func (m *Memory) UpdateChannel(_ context.Context, c Channel) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	old, ok := m.ch().chans[c.ID]
	if !ok {
		return ErrNotFound
	}
	old.Name, old.Description, old.Emoji = c.Name, c.Description, c.Emoji
	m.ch().chans[c.ID] = old
	return nil
}

func (m *Memory) DeleteChannel(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cs := m.ch()
	delete(cs.chans, id)
	delete(cs.followers, id)
	delete(cs.posts, id)
	delete(cs.logos, id)
	return nil
}

func (m *Memory) SetChannelLogo(_ context.Context, id string, img []byte) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cs := m.ch()
	c, ok := cs.chans[id]
	if !ok {
		return 0, ErrNotFound
	}
	if len(img) == 0 {
		delete(cs.logos, id)
		c.LogoV = 0
	} else {
		cs.logos[id] = img
		v := c.LogoV
		if v < 0 {
			v = -v
		}
		c.LogoV = v + 1
	}
	cs.chans[id] = c
	return c.LogoV, nil
}

func (m *Memory) SetChannelOfficial(_ context.Context, id string, official bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.ch().chans[id]
	if !ok {
		return ErrNotFound
	}
	c.Official = official
	m.ch().chans[id] = c
	return nil
}

func (m *Memory) OfficialChannels(_ context.Context) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []string{}
	for id, c := range m.ch().chans {
		if c.Official && m.chanAliveLocked(c) {
			out = append(out, id)
		}
	}
	return out, nil
}

func (m *Memory) ChannelLogo(_ context.Context, id string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	img, ok := m.ch().logos[id]
	if !ok {
		return nil, ErrNotFound
	}
	return img, nil
}

func (m *Memory) Channel(_ context.Context, id, viewer string) (Channel, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.ch().chans[id]
	if !ok || !m.chanAliveLocked(c) {
		return Channel{}, ErrNotFound
	}
	return m.chanViewLocked(c, viewer), nil
}

func (m *Memory) Channels(_ context.Context, q, viewer string, limit int) ([]Channel, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	q = strings.ToLower(strings.TrimSpace(q))
	out := []Channel{}
	for _, c := range m.ch().chans {
		if !m.chanAliveLocked(c) {
			continue
		}
		if q != "" && !strings.Contains(strings.ToLower(c.Name), q) && !strings.Contains(strings.ToLower(c.Description), q) {
			continue
		}
		out = append(out, m.chanViewLocked(c, viewer))
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Official != out[j].Official {
			return out[i].Official
		}
		if out[i].Followers != out[j].Followers {
			return out[i].Followers > out[j].Followers
		}
		return out[i].CreatedAt.After(out[j].CreatedAt)
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *Memory) MyChannels(_ context.Context, viewer string) ([]Channel, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []Channel{}
	for id, c := range m.ch().chans {
		if !m.chanAliveLocked(c) || (c.OwnerID != viewer && !m.ch().followers[id][viewer]) {
			continue
		}
		out = append(out, m.chanViewLocked(c, viewer))
	}
	sortByLast(out)
	return out, nil
}

func sortByLast(out []Channel) {
	at := func(c Channel) time.Time {
		if c.LastAt != nil {
			return *c.LastAt
		}
		return c.CreatedAt
	}
	sort.Slice(out, func(i, j int) bool { return at(out[i]).After(at(out[j])) })
}

func (m *Memory) CountOwnedChannels(_ context.Context, owner string) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, c := range m.ch().chans {
		if c.OwnerID == owner {
			n++
		}
	}
	return n, nil
}

func (m *Memory) FollowChannel(_ context.Context, id, acc string, follow bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cs := m.ch()
	if _, ok := cs.chans[id]; !ok {
		return ErrNotFound
	}
	if _, ok := m.accounts[acc]; !ok {
		return ErrNotFound
	}
	if cs.followers[id] == nil {
		cs.followers[id] = map[string]bool{}
	}
	if follow {
		cs.followers[id][acc] = true
	} else {
		delete(cs.followers[id], acc)
	}
	return nil
}

func (m *Memory) AddChanPost(_ context.Context, p ChanPost) (ChanPost, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cs := m.ch()
	if _, ok := cs.chans[p.ChannelID]; !ok {
		return ChanPost{}, ErrNotFound
	}
	p.ID = uuid.NewString()
	p.CreatedAt = time.Now()
	p.HasImage = len(p.Image) > 0
	cs.posts[p.ChannelID] = append(cs.posts[p.ChannelID], p)
	p.Image = nil
	return p, nil
}

func (m *Memory) DeleteChanPost(_ context.Context, channelID, postID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cs := m.ch()
	ps := cs.posts[channelID]
	for i, p := range ps {
		if p.ID == postID {
			cs.posts[channelID] = append(ps[:i:i], ps[i+1:]...)
			return nil
		}
	}
	return ErrNotFound
}

func (m *Memory) ChanPosts(_ context.Context, channelID string, before time.Time, limit int) ([]ChanPost, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ps := m.ch().posts[channelID]
	out := []ChanPost{}
	for i := len(ps) - 1; i >= 0 && len(out) < limit; i-- {
		if before.IsZero() || ps[i].CreatedAt.Before(before) {
			p := ps[i]
			p.Image = nil
			out = append(out, p)
		}
	}
	return out, nil
}

func (m *Memory) ChanPostImage(_ context.Context, channelID, postID string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, p := range m.ch().posts[channelID] {
		if p.ID == postID && len(p.Image) > 0 {
			return p.Image, nil
		}
	}
	return nil, ErrNotFound
}

// ---------- Postgres ----------

const chanCols = `c.id::text, c.owner_id::text, c.name, c.description, c.emoji, c.logo_v, c.created_at,
	(SELECT count(*) FROM channel_followers f WHERE f.channel_id = c.id),
	EXISTS (SELECT 1 FROM channel_followers f WHERE f.channel_id = c.id AND f.account_id = $1),
	lp.id::text, lp.body, lp.has_image, lp.created_at, c.official`

const chanFrom = ` FROM channels c LEFT JOIN LATERAL (
	SELECT p.id, p.body, p.image IS NOT NULL AS has_image, p.created_at FROM channel_posts p WHERE p.channel_id = c.id
	ORDER BY p.created_at DESC LIMIT 1) lp ON true`

func scanChannels(rows pgx.Rows, viewer string) ([]Channel, error) {
	defer rows.Close()
	out := []Channel{}
	for rows.Next() {
		var c Channel
		var pid, pbody *string
		var pimg *bool
		var pat *time.Time
		if err := rows.Scan(&c.ID, &c.OwnerID, &c.Name, &c.Description, &c.Emoji, &c.LogoV, &c.CreatedAt,
			&c.Followers, &c.Following, &pid, &pbody, &pimg, &pat, &c.Official); err != nil {
			return nil, err
		}
		c.Mine = c.OwnerID == viewer
		if pid != nil && pbody != nil && pat != nil {
			c.LastPost = &ChanPost{ID: *pid, ChannelID: c.ID, Body: *pbody, HasImage: pimg != nil && *pimg, CreatedAt: *pat}
			c.LastAt = pat
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (p *Postgres) CreateChannel(ctx context.Context, c Channel) (Channel, error) {
	c.ID = uuid.NewString()
	err := p.pool.QueryRow(ctx, `INSERT INTO channels (id, owner_id, name, description, emoji)
		VALUES ($1, $2, $3, $4, $5) RETURNING created_at`, c.ID, c.OwnerID, c.Name, c.Description, c.Emoji).Scan(&c.CreatedAt)
	c.Mine = true
	return c, err
}

func (p *Postgres) UpdateChannel(ctx context.Context, c Channel) error {
	tag, err := p.pool.Exec(ctx, `UPDATE channels SET name = $2, description = $3, emoji = $4 WHERE id = $1`,
		c.ID, c.Name, c.Description, c.Emoji)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

func (p *Postgres) DeleteChannel(ctx context.Context, id string) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM channels WHERE id = $1`, id)
	return err
}

func (p *Postgres) Channel(ctx context.Context, id, viewer string) (Channel, error) {
	if _, err := uuid.Parse(id); err != nil {
		return Channel{}, ErrNotFound
	}
	rows, err := p.pool.Query(ctx, `SELECT `+chanCols+chanFrom+` WHERE c.id = $2`, viewer, id)
	if err != nil {
		return Channel{}, err
	}
	out, err := scanChannels(rows, viewer)
	if err != nil {
		return Channel{}, err
	}
	if len(out) == 0 {
		return Channel{}, ErrNotFound
	}
	return out[0], nil
}

func (p *Postgres) Channels(ctx context.Context, q, viewer string, limit int) ([]Channel, error) {
	q = strings.TrimSpace(q)
	rows, err := p.pool.Query(ctx, `SELECT `+chanCols+chanFrom+`
		WHERE ($2 = '' OR c.name ILIKE '%' || $2 || '%' OR c.description ILIKE '%' || $2 || '%')
		ORDER BY c.official DESC, 8 DESC, c.created_at DESC LIMIT $3`, viewer, q, limit)
	if err != nil {
		return nil, err
	}
	return scanChannels(rows, viewer)
}

func (p *Postgres) MyChannels(ctx context.Context, viewer string) ([]Channel, error) {
	rows, err := p.pool.Query(ctx, `SELECT `+chanCols+chanFrom+`
		WHERE c.owner_id = $1 OR EXISTS (SELECT 1 FROM channel_followers f WHERE f.channel_id = c.id AND f.account_id = $1)
		LIMIT 300`, viewer)
	if err != nil {
		return nil, err
	}
	out, err := scanChannels(rows, viewer)
	if err == nil {
		sortByLast(out)
	}
	return out, err
}

func (p *Postgres) CountOwnedChannels(ctx context.Context, owner string) (int, error) {
	var n int
	err := p.pool.QueryRow(ctx, `SELECT count(*) FROM channels WHERE owner_id = $1`, owner).Scan(&n)
	return n, err
}

func (p *Postgres) FollowChannel(ctx context.Context, id, acc string, follow bool) error {
	var err error
	if follow {
		_, err = p.pool.Exec(ctx, `INSERT INTO channel_followers (channel_id, account_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING`, id, acc)
	} else {
		_, err = p.pool.Exec(ctx, `DELETE FROM channel_followers WHERE channel_id = $1 AND account_id = $2`, id, acc)
	}
	return err
}

func (p *Postgres) AddChanPost(ctx context.Context, cp ChanPost) (ChanPost, error) {
	cp.ID = uuid.NewString()
	var img []byte
	if len(cp.Image) > 0 {
		img = cp.Image
	}
	err := p.pool.QueryRow(ctx, `INSERT INTO channel_posts (id, channel_id, body, image) VALUES ($1, $2, $3, $4)
		RETURNING created_at`, cp.ID, cp.ChannelID, cp.Body, img).Scan(&cp.CreatedAt)
	cp.HasImage = img != nil
	cp.Image = nil
	return cp, err
}

func (p *Postgres) DeleteChanPost(ctx context.Context, channelID, postID string) error {
	if _, err := uuid.Parse(postID); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `DELETE FROM channel_posts WHERE id = $1 AND channel_id = $2`, postID, channelID)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

func (p *Postgres) ChanPosts(ctx context.Context, channelID string, before time.Time, limit int) ([]ChanPost, error) {
	if before.IsZero() {
		before = time.Now().Add(time.Hour)
	}
	rows, err := p.pool.Query(ctx, `SELECT id::text, channel_id::text, body, image IS NOT NULL, created_at FROM channel_posts
		WHERE channel_id = $1 AND created_at < $2 ORDER BY created_at DESC LIMIT $3`, channelID, before, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ChanPost{}
	for rows.Next() {
		var cp ChanPost
		if err := rows.Scan(&cp.ID, &cp.ChannelID, &cp.Body, &cp.HasImage, &cp.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, cp)
	}
	return out, rows.Err()
}

func (p *Postgres) ChanPostImage(ctx context.Context, channelID, postID string) ([]byte, error) {
	if _, err := uuid.Parse(channelID); err != nil {
		return nil, ErrNotFound
	}
	if _, err := uuid.Parse(postID); err != nil {
		return nil, ErrNotFound
	}
	var img []byte
	err := p.pool.QueryRow(ctx, `SELECT image FROM channel_posts WHERE id = $1 AND channel_id = $2 AND image IS NOT NULL`,
		postID, channelID).Scan(&img)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return img, err
}

func (p *Postgres) SetChannelLogo(ctx context.Context, id string, img []byte) (int, error) {
	if _, err := uuid.Parse(id); err != nil {
		return 0, ErrNotFound
	}
	var v int
	var err error
	if len(img) == 0 {
		err = p.pool.QueryRow(ctx, `UPDATE channels SET logo = NULL, logo_v = 0 WHERE id = $1 RETURNING logo_v`, id).Scan(&v)
	} else {
		err = p.pool.QueryRow(ctx, `UPDATE channels SET logo = $2, logo_v = abs(logo_v) + 1 WHERE id = $1 RETURNING logo_v`, id, img).Scan(&v)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	}
	return v, err
}

func (p *Postgres) ChannelLogo(ctx context.Context, id string) ([]byte, error) {
	if _, err := uuid.Parse(id); err != nil {
		return nil, ErrNotFound
	}
	var img []byte
	err := p.pool.QueryRow(ctx, `SELECT logo FROM channels WHERE id = $1 AND logo IS NOT NULL`, id).Scan(&img)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return img, err
}

func (p *Postgres) SetChannelOfficial(ctx context.Context, id string, official bool) error {
	if _, err := uuid.Parse(id); err != nil {
		return ErrNotFound
	}
	tag, err := p.pool.Exec(ctx, `UPDATE channels SET official = $2 WHERE id = $1`, id, official)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

func (p *Postgres) OfficialChannels(ctx context.Context) ([]string, error) {
	rows, err := p.pool.Query(ctx, `SELECT id::text FROM channels WHERE official`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func (m *Memory) FollowChannelAll(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cs := m.ch()
	if _, ok := cs.chans[id]; !ok {
		return ErrNotFound
	}
	if cs.followers[id] == nil {
		cs.followers[id] = map[string]bool{}
	}
	for acc := range m.accounts {
		cs.followers[id][acc] = true
	}
	return nil
}

func (p *Postgres) FollowChannelAll(ctx context.Context, id string) error {
	if _, err := uuid.Parse(id); err != nil {
		return ErrNotFound
	}
	_, err := p.pool.Exec(ctx, `INSERT INTO channel_followers (channel_id, account_id)
		SELECT $1, id FROM accounts ON CONFLICT DO NOTHING`, id)
	return err
}
