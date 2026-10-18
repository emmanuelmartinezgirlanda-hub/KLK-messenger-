package blob

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

const prefix = "att/"

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
	return b.S3.Put(ctx, prefix+id, data)
}

func (b *Store) GetAttachment(ctx context.Context, id string) ([]byte, error) {
	data, err := b.S3.Get(ctx, prefix+id)
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
	objs, err := b.S3.List(ctx, prefix)
	if err != nil {
		return n, err
	}
	for _, o := range objs {
		if o.LastModified.Before(before) {
			if err := b.S3.Delete(ctx, o.Key); err == nil {
				n++
			}
		}
	}
	return n, nil
}
