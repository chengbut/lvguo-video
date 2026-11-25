package core

import (
	"context"
	"fmt"
	"net/url"
	"strings"
)

type providerTextUserAgentKey struct{}
type providerTextNoCacheKey struct{}
type providerTextCookieKey struct{}
type providerTextMirrorsKey struct{}

func (d *Downloader) prepareWebProviderMedia(ctx context.Context, media ProviderMedia, sourceName string) (ProviderMedia, error) {
	address, err := url.Parse(media.URL)
	if err != nil || !IsProviderHTTPMediaURL(media.URL) || address.User != nil {
		return ProviderMedia{}, fmt.Errorf("%s未返回有效播放地址，请刷新详情后重试", sourceName)
	}
	if strings.HasSuffix(strings.ToLower(address.Path), ".m3u8") {
		if media.Credentials != nil {
			ctx = providerMediaContext(ctx, media.Credentials)
		}
		media.Playlist, media.URL, err = d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return ProviderMedia{}, fmt.Errorf("获取%s播放列表失败：%w", sourceName, err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(media.Playlist, "\ufeff")), "#EXTM3U") {
			return ProviderMedia{}, fmt.Errorf("%s播放列表无效，请重新解析播放", sourceName)
		}
		if duration := M3u8Duration(media.Playlist); duration > 0 {
			media.Duration = duration
		}
	}
	return media, nil
}
