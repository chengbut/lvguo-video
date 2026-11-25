package core

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"fmt"
)

type moduleIndexEntry struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Version     string            `json:"version"`
	Description string            `json:"description"`
	API         int               `json:"api"`
	Adult       bool              `json:"adult"`
	Repo        string            `json:"repo"`
	Tag         string            `json:"tag"`
	SHA256      map[string]string `json:"sha256"`
	Bundled     bool              `json:"bundled,omitempty"`
}

// moduleStore 只返回随安装包内置的模块（当前没有内置任何模块）。
// 在线模块索引已彻底移除：不保存索引地址，也不再从网络拉取索引或模块。
func (engine *nativeEngine) moduleStore(ctx context.Context) (map[string]any, error) {
	return map[string]any{"items": bundledIndexEntries()}, nil
}

func (engine *nativeEngine) indexedModulePackage(ctx context.Context, id string, bundled bool) ([]byte, error) {
	if bundled {
		modules, _ := readBundledModules()
		if modules[id].raw == nil {
			return nil, fmt.Errorf("安装包没有内置 %s", id)
		}
		return zipModuleFiles(modules[id].raw, modules[id].code)
	}
	return nil, errors.New("在线模块索引已移除，请手动安装模块")
}

func zipModuleFiles(manifest, code []byte) ([]byte, error) {
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for _, file := range []struct {
		name string
		data []byte
	}{{moduleManifest, manifest}, {moduleEntry, code}} {
		writer, err := archive.Create(file.name)
		if err != nil {
			return nil, err
		}
		if _, err := writer.Write(file.data); err != nil {
			return nil, err
		}
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}
