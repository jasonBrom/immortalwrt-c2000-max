// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Lightweight Go backend compatible with the LibreSpeed/Speedtest-X Web UI.
// The bundled Speedtest-X assets retain their original license and notices.
package main

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	version             = "1.0.0"
	defaultDownloadMiB  = 50
	maxUploadBody       = 256 << 20
	downloadBufferBytes = 256 << 10
)

//go:embed web/*
var embeddedWeb embed.FS

type result struct {
	Key       string    `json:"key"`
	IP        string    `json:"ip"`
	ISP       string    `json:"isp"`
	Address   string    `json:"addr"`
	Download  string    `json:"download"`
	Upload    string    `json:"upload"`
	Ping      string    `json:"ping"`
	Jitter    string    `json:"jitter"`
	UpdatedAt time.Time `json:"updated_at"`
}

type history struct {
	mu      sync.RWMutex
	limit   int
	results []result
}

func (h *history) update(item result) {
	if h.limit <= 0 {
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	for i := range h.results {
		if h.results[i].Key == item.Key {
			h.results[i] = item
			return
		}
	}

	h.results = append([]result{item}, h.results...)
	if len(h.results) > h.limit {
		h.results = h.results[:h.limit]
	}
}

func (h *history) snapshot() []result {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]result, len(h.results))
	copy(out, h.results)
	return out
}

type server struct {
	maxDownloadMiB int64
	slots          chan struct{}
	payload        []byte
	history        *history
	uploadBuffers  sync.Pool
}

func newServer(maxDownloadMiB, maxClients, historyLimit int) *server {
	if maxDownloadMiB < 1 {
		maxDownloadMiB = defaultDownloadMiB
	}
	if maxDownloadMiB > 1024 {
		maxDownloadMiB = 1024
	}
	if maxClients < 12 {
		maxClients = 12
	}
	if maxClients > 128 {
		maxClients = 128
	}
	if historyLimit < 0 {
		historyLimit = 0
	}
	if historyLimit > 1000 {
		historyLimit = 1000
	}

	payload := make([]byte, downloadBufferBytes)
	if _, err := rand.Read(payload); err != nil {
		for i := range payload {
			payload[i] = byte((i*131 + 17) & 0xff)
		}
	}

	s := &server{
		maxDownloadMiB: int64(maxDownloadMiB),
		slots:          make(chan struct{}, maxClients),
		payload:        payload,
		history:        &history{limit: historyLimit},
	}
	s.uploadBuffers.New = func() any {
		buffer := make([]byte, 128<<10)
		return &buffer
	}
	return s
}

func noCache(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Expires", "0")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
}

func (s *server) withSlot(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		select {
		case s.slots <- struct{}{}:
			defer func() { <-s.slots }()
			next(w, r)
		case <-r.Context().Done():
			return
		default:
			http.Error(w, "speed-test server busy", http.StatusServiceUnavailable)
		}
	}
}

func (s *server) download(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	sizeMiB := int64(defaultDownloadMiB)
	if value := r.URL.Query().Get("ckSize"); value != "" {
		if parsed, err := strconv.ParseInt(value, 10, 64); err == nil {
			sizeMiB = parsed
		}
	}
	if sizeMiB < 1 {
		sizeMiB = 1
	}
	if sizeMiB > s.maxDownloadMiB {
		sizeMiB = s.maxDownloadMiB
	}
	remaining := sizeMiB << 20

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(remaining, 10))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Method == http.MethodHead {
		return
	}

	for remaining > 0 {
		chunk := int64(len(s.payload))
		if remaining < chunk {
			chunk = remaining
		}
		if _, err := w.Write(s.payload[:chunk]); err != nil {
			return
		}
		remaining -= chunk
	}
}

func (s *server) empty(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method == http.MethodPost {
		r.Body = http.MaxBytesReader(w, r.Body, maxUploadBody)
		buffer := s.uploadBuffers.Get().(*[]byte)
		_, err := io.CopyBuffer(io.Discard, r.Body, *buffer)
		s.uploadBuffers.Put(buffer)
		if err != nil {
			http.Error(w, "upload rejected", http.StatusRequestEntityTooLarge)
			return
		}
	}
	w.WriteHeader(http.StatusOK)
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return strings.Trim(r.RemoteAddr, "[]")
}

func (s *server) getIP(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	ip := clientIP(r)
	if r.URL.Query().Get("isp") == "true" {
		fmt.Fprintf(w, "%s - LAN - C2000-MAX", ip)
		return
	}
	io.WriteString(w, ip)
}

func safeField(value string, max int) string {
	value = strings.TrimSpace(value)
	if len(value) > max {
		value = value[:max]
	}
	return value
}

func (s *server) report(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", http.StatusBadRequest)
		return
	}
	key := safeField(r.FormValue("key"), 160)
	if key == "" {
		key = strconv.FormatInt(time.Now().UnixNano(), 10) + "_" + clientIP(r)
	}
	item := result{
		Key:       key,
		IP:        safeField(r.FormValue("ip"), 96),
		ISP:       safeField(r.FormValue("isp"), 96),
		Address:   safeField(r.FormValue("addr"), 128),
		Download:  safeField(r.FormValue("dspeed"), 32),
		Upload:    safeField(r.FormValue("uspeed"), 32),
		Ping:      safeField(r.FormValue("ping"), 32),
		Jitter:    safeField(r.FormValue("jitter"), 32),
		UpdatedAt: time.Now(),
	}
	if item.IP == "" {
		item.IP = clientIP(r)
	}
	s.history.update(item)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	io.WriteString(w, "{\"ok\":true}")
}

func (s *server) results(w http.ResponseWriter, r *http.Request) {
	noCache(w)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(s.history.snapshot())
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	noCache(w)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	fmt.Fprintf(w, "{\"ok\":true,\"version\":%q,\"active_streams\":%d}", version, len(s.slots))
}

func (s *server) handler() (http.Handler, error) {
	webRoot, err := fs.Sub(embeddedWeb, "web")
	if err != nil {
		return nil, err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/backend/garbage.php", s.withSlot(s.download))
	mux.HandleFunc("/backend/empty.php", s.withSlot(s.empty))
	mux.HandleFunc("/backend/getIP.php", s.getIP)
	mux.HandleFunc("/backend/report.php", s.report)
	mux.HandleFunc("/backend/results-api.php", s.results)
	mux.HandleFunc("/healthz", s.health)
	mux.Handle("/", http.FileServer(http.FS(webRoot)))
	return mux, nil
}

func main() {
	var (
		listen         = flag.String("listen", "0.0.0.0:9001", "HTTP listen address")
		maxDownloadMiB = flag.Int("max-download-mb", defaultDownloadMiB, "maximum download response size in MiB")
		maxClients     = flag.Int("max-clients", 24, "maximum simultaneous upload/download streams")
		historyLimit   = flag.Int("history-limit", 100, "maximum in-memory result records; zero disables history")
		showVersion    = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	app := newServer(*maxDownloadMiB, *maxClients, *historyLimit)
	handler, err := app.handler()
	if err != nil {
		log.Fatal(err)
	}

	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("Speedtest-X Go %s listening on %s", version, *listen)
	err = httpServer.ListenAndServe()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
