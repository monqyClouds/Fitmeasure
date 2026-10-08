package web

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAssetLinks(t *testing.T) {
	h, err := AssetLinks("com.fitmeasure.fitmeasure:a0babc5bee3a993c782289bbaaf3e0937e0e99b8cabebcfc3a5d5e4456fc48f7")
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/.well-known/assetlinks.json", nil))
	body, _ := io.ReadAll(rec.Body)
	for _, want := range []string{`"package_name":"com.fitmeasure.fitmeasure"`, `"A0:BA:BC:5B:`, `:48:F7"`, `handle_all_urls`} {
		if !strings.Contains(string(body), want) {
			t.Errorf("missing %s in %s", want, body)
		}
	}
	for _, bad := range []string{"", "com.x", "com.x:abc", "com.x:" + strings.Repeat("zz", 32)} {
		if _, err := AssetLinks(bad); err == nil {
			t.Errorf("AssetLinks(%q) accepted", bad)
		}
	}
}

func TestRoomPage(t *testing.T) {
	rec := httptest.NewRecorder()
	RoomPage().ServeHTTP(rec, httptest.NewRequest("GET", "/r/k7f3qz", nil))
	if !strings.Contains(rec.Body.String(), `src="/room/room.js"`) {
		t.Fatal("the room page doesn't load its script from an absolute path")
	}
}
