// Package web embeds the browser test pages for the SFU stages.
package web

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed static
var files embed.FS

// Handler serves the pages, sending / to the echo test.
func Handler() http.Handler {
	static, _ := fs.Sub(files, "static")
	fileServer := http.FileServerFS(static)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/echo/", http.StatusFound)
			return
		}
		fileServer.ServeHTTP(w, r)
	})
}
