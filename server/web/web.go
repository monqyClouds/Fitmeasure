// Package web embeds the browser pages: the SFU stages' test pages, and
// the room page that room links open.
package web

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"regexp"
	"strings"
)

//go:embed static
var files embed.FS

// Handler serves the pages, sending / to the latest stage's page.
func Handler() http.Handler {
	static, _ := fs.Sub(files, "static")
	fileServer := http.FileServerFS(static)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/room/", http.StatusFound)
			return
		}
		fileServer.ServeHTTP(w, r)
	})
}

// RoomPage serves the room page for a room's link, /r/{id}; the page reads
// the ID from its address.
func RoomPage() http.Handler {
	page, err := files.ReadFile("static/room/index.html")
	if err != nil {
		panic(err) // embedded at build time
	}
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(page)
	})
}

var fingerprint = regexp.MustCompile(`^([0-9A-Fa-f]{2}:?){32}$`)

// AssetLinks serves /.well-known/assetlinks.json, which lets an Android
// app open this site's room links. spec is "package:sha256[,sha256…]",
// with the SHA-256 of each certificate the app is signed with, colons
// optional.
func AssetLinks(spec string) (http.Handler, error) {
	pkg, prints, ok := strings.Cut(spec, ":")
	if !ok || pkg == "" {
		return nil, fmt.Errorf("expected package:sha256, got %q", spec)
	}
	var formatted []string
	for _, fp := range strings.Split(prints, ",") {
		fp = strings.TrimSpace(fp)
		if !fingerprint.MatchString(fp) {
			return nil, fmt.Errorf("%q is not a SHA-256 fingerprint", fp)
		}
		hex := strings.ToUpper(strings.ReplaceAll(fp, ":", ""))
		pairs := make([]string, 0, 32)
		for i := 0; i < len(hex); i += 2 {
			pairs = append(pairs, hex[i:i+2])
		}
		formatted = append(formatted, strings.Join(pairs, ":"))
	}
	body, err := json.Marshal([]any{map[string]any{
		"relation": []string{"delegate_permission/common.handle_all_urls"},
		"target": map[string]any{
			"namespace":                "android_app",
			"package_name":             pkg,
			"sha256_cert_fingerprints": formatted,
		},
	}})
	if err != nil {
		return nil, err
	}
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}), nil
}
