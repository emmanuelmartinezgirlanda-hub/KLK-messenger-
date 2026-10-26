package blob

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/klk-app/klk-server/internal/store"
)

// Fotos de Negocios (logo y productos) y de Mi Gente: los bytes van a R2 y en
// la base de datos solo queda la ficha (dueño, tipo, fecha). Así la base de
// datos no se llena. Las fotos antiguas que ya estaban en la base de datos se
// siguen leyendo de allí.
const (
	bizPrefix   = "biz/"
	gentePrefix = "gente/"
)

func (b *Store) PutBusinessImage(ctx context.Context, img store.BusinessImage) error {
	return b.putImage(ctx, bizPrefix, img, b.Store.PutBusinessImage)
}

func (b *Store) GetBusinessImage(ctx context.Context, id string) (store.BusinessImage, error) {
	return b.getImage(ctx, bizPrefix, id, b.Store.GetBusinessImage)
}

func (b *Store) PutGenteImage(ctx context.Context, img store.BusinessImage) error {
	return b.putImage(ctx, gentePrefix, img, b.Store.PutGenteImage)
}

func (b *Store) GetGenteImage(ctx context.Context, id string) (store.BusinessImage, error) {
	return b.getImage(ctx, gentePrefix, id, b.Store.GetGenteImage)
}

func (b *Store) putImage(ctx context.Context, prefix string, img store.BusinessImage,
	put func(context.Context, store.BusinessImage) error) error {
	if ok, err := b.Store.AccountExists(ctx, img.Owner); err == nil && !ok {
		return store.ErrNotFound
	}
	if err := b.S3.Put(ctx, prefix+img.ID, img.Data); err != nil {
		return err
	}
	meta := img
	meta.Data = nil // los bytes ya están en R2
	if err := put(ctx, meta); err != nil {
		b.S3.Delete(ctx, prefix+img.ID)
		return err
	}
	return nil
}

func (b *Store) getImage(ctx context.Context, prefix, id string,
	get func(context.Context, string) (store.BusinessImage, error)) (store.BusinessImage, error) {
	img, err := get(ctx, id) // comprueba que existe y que su dueño no está bloqueado
	if err != nil || len(img.Data) > 0 {
		return img, err // o una foto antigua guardada en la base de datos
	}
	data, err := b.S3.Get(ctx, prefix+id)
	if errors.Is(err, ErrNotFound) {
		return store.BusinessImage{}, store.ErrNotFound
	}
	if err != nil {
		return store.BusinessImage{}, err
	}
	img.Data = data
	return img, nil
}

// sweepImages borra de R2 las fotos cuya ficha ya no existe (cambió el logo,
// borró la publicación o la cuenta…). Deja en paz las de la última hora.
func (b *Store) sweepImages(ctx context.Context, now time.Time) int {
	n := 0
	for kind, prefix := range map[string]string{"biz": bizPrefix, "gente": gentePrefix} {
		objs, err := b.S3.List(ctx, prefix)
		if err != nil {
			slog.Warn("listar fotos en R2", "prefix", prefix, "err", err)
			continue
		}
		for _, o := range objs {
			if o.LastModified.After(now.Add(-time.Hour)) {
				continue
			}
			id := strings.TrimPrefix(o.Key, prefix)
			ok, err := b.Store.ImageExists(ctx, kind, id)
			if err != nil || ok {
				continue
			}
			if b.S3.Delete(ctx, o.Key) == nil {
				n++
			}
		}
	}
	return n
}
