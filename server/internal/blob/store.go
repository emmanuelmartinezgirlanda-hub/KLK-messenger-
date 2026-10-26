package blob

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

const (
	prefix     = "att/"  // se borran a los 30 días (y regla de R2 sobre att/)
	plusPrefix = "attp/" // KLK Plus: se guardan 1 año
)

// PlusKeep es cuánto se guardan los adjuntos de quien tiene Plus.
const PlusKeep = 365 * 24 * time.Hour

// Store envuelve el almacén normal: los adjuntos nuevos van a S3/R2 y los
// antiguos (de antes del cambio) se siguen leyendo de la base de datos.
type Store struct {
	store.Store
	S3 *S3
}

func (b *Store) PutAttachment(ctx context.Context, id, owner string, data []byte) error {
	if ok, err := b.Store.AccountExists(ctx, owner); err == nil && !ok {
		return store.ErrNotFound
	}
	if store.HasPlus(ctx, b.Store, owner, time.Now()) {
		return b.S3.Put(ctx, plusPrefix+id, data)
	}
	return b.S3.Put(ctx, prefix+id, data)
}

func (b *Store) GetAttachment(ctx context.Context, id string) ([]byte, error) {
	data, err := b.S3.Get(ctx, prefix+id)
	if errors.Is(err, ErrNotFound) {
		data, err = b.S3.Get(ctx, plusPrefix+id)
	}
	if errors.Is(err, ErrNotFound) {
		return b.Store.GetAttachment(ctx, id) // adjunto antiguo en la base de datos
	}
	return data, err
}

// PurgeAttachments borra los antiguos de la base de datos y los de R2 de más de 30 días.
func (b *Store) PurgeAttachments(ctx context.Context, before time.Time) (int, error) {
	n, err := b.Store.PurgeAttachments(ctx, before)
	if err != nil {
		slog.Warn("purga de adjuntos (base de datos)", "err", err)
	}
	// Los de Plus duran 1 año en vez de 30 días.
	plusBefore := before.Add(-(PlusKeep - 30*24*time.Hour))
	for _, pr := range []struct {
		p      string
		before time.Time
	}{{prefix, before}, {plusPrefix, plusBefore}} {
		objs, err := b.S3.List(ctx, pr.p)
		if err != nil {
			return n, err
		}
		for _, o := range objs {
			if o.LastModified.Before(pr.before) {
				if err := b.S3.Delete(ctx, o.Key); err == nil {
					n++
				}
			}
		}
	}
	n += b.sweepImages(ctx, time.Now())
	return n, nil
}
