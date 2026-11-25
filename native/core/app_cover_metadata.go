package core

import (
	"context"
	"errors"
)

func (d *Downloader) nativeCoverAddress(ctx context.Context, drama LibraryDrama) (string, error) {
	source, id, valid := SplitProviderDramaID(drama.ID)
	if !valid {
		return "", errors.New("无效的剧集 ID")
	}
	if p, ok := d.provider(source); ok {
		if resolver, ok := providerAs[CoverResolver](p); ok {
			return resolver.CoverAddress(ctx, drama, id)
		}
		fresh, _, err := p.Detail(ctx, id)
		return NativeNormalize(fresh).Cover, err
	}
	return "", errors.New("该站源暂无封面补齐接口")
}
