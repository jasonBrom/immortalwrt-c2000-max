package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type testBackend struct{}

func (testBackend) Execute(_ context.Context, command string) (string, error) {
	return command + "\r\n+CSQ: 23,99\r\nOK", nil
}

func (testBackend) Close() error   { return nil }
func (testBackend) Target() string { return "test-at" }

func testApp(t *testing.T) *webApp {
	t.Helper()
	root, err := fs.Sub(embeddedWeb, "web")
	if err != nil {
		t.Fatal(err)
	}
	return &webApp{
		config:  serverConfig{Listen: "127.0.0.1:9010", Transport: "serial", Timeout: 4e9},
		hub:     newHub(4),
		backend: testBackend{},
		web:     http.StripPrefix("/5700/", http.FileServer(http.FS(root))),
	}
}

func TestHTTPRoutes(t *testing.T) {
	server := httptest.NewServer(testApp(t))
	defer server.Close()
	for _, path := range []string{"/healthz", "/cgi-bin/at-ws-info", "/5700/", "/scripts/loading.js"} {
		response, err := http.Get(server.URL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		_, _ = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("GET %s returned %d", path, response.StatusCode)
		}
	}
}

func writeMaskedText(t *testing.T, conn net.Conn, text string) {
	t.Helper()
	payload := []byte(text)
	header := []byte{0x81}
	switch {
	case len(payload) < 126:
		header = append(header, 0x80|byte(len(payload)))
	case len(payload) <= 65535:
		header = append(header, 0x80|126, 0, 0)
		binary.BigEndian.PutUint16(header[len(header)-2:], uint16(len(payload)))
	default:
		t.Fatal("test payload too large")
	}
	mask := []byte{1, 2, 3, 4}
	header = append(header, mask...)
	for index := range payload {
		payload[index] ^= mask[index%4]
	}
	if _, err := conn.Write(append(header, payload...)); err != nil {
		t.Fatal(err)
	}
}

func readServerText(t *testing.T, reader *bufio.Reader) string {
	t.Helper()
	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil {
		t.Fatal(err)
	}
	length := uint64(header[1] & 0x7f)
	if length == 126 {
		extra := make([]byte, 2)
		if _, err := io.ReadFull(reader, extra); err != nil {
			t.Fatal(err)
		}
		length = uint64(binary.BigEndian.Uint16(extra))
	} else if length == 127 {
		extra := make([]byte, 8)
		if _, err := io.ReadFull(reader, extra); err != nil {
			t.Fatal(err)
		}
		length = binary.BigEndian.Uint64(extra)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		t.Fatal(err)
	}
	return string(payload)
}

func TestWebSocketATProtocol(t *testing.T) {
	server := httptest.NewServer(testApp(t))
	defer server.Close()
	parsed, _ := url.Parse(server.URL)
	conn, err := net.Dial("tcp", parsed.Host)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	request := "GET / HTTP/1.1\r\nHost: " + parsed.Host + "\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
	if _, err := conn.Write([]byte(request)); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	status, err := reader.ReadString('\n')
	if err != nil || !strings.Contains(status, "101") {
		t.Fatalf("handshake failed: %q, %v", status, err)
	}
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == "\r\n" {
			break
		}
	}

	writeMaskedText(t, conn, "ping")
	if response := readServerText(t, reader); response != "pong" {
		t.Fatalf("unexpected heartbeat response: %q", response)
	}
	writeMaskedText(t, conn, "AT+CSQ")
	var response atResponse
	if err := json.Unmarshal([]byte(readServerText(t, reader)), &response); err != nil {
		t.Fatal(err)
	}
	if !response.Success || !strings.Contains(response.Data, "+CSQ: 23,99") {
		t.Fatalf("unexpected AT response: %+v", response)
	}
}

func TestATResponseDetection(t *testing.T) {
	if !finalATResponse([]byte("AT+CSQ\r\n+CSQ: 20,99\r\nOK\r\n")) {
		t.Fatal("OK response not detected")
	}
	if finalATResponse([]byte("+CSQ: 20,99\r\n")) {
		t.Fatal("partial response detected as complete")
	}
	cleaned := cleanATResponse("AT+CSQ", []byte("AT+CSQ\r\n+CSQ: 20,99\r\nOK\r\n"))
	if strings.Contains(cleaned, "AT+CSQ") || !strings.Contains(cleaned, "+CSQ") {
		t.Fatalf("unexpected cleaned response: %q", cleaned)
	}
}

func TestQModemQueuedBackend(t *testing.T) {
	dir := t.TempDir()
	helper := filepath.Join(dir, "qmodem-at")
	script := "#!/bin/sh\nprintf '%s\\r\\n+CSQ: 31,99\\r\\nOK\\r\\n' \"$3\"\n"
	if err := os.WriteFile(helper, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	backend := newQModemQueuedBackend("auto", "/dev/mock-at", helper, 2*time.Second, 10*time.Second)
	defer backend.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	response, err := backend.Execute(ctx, "AT+CSQ")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(response, "+CSQ: 31,99") || strings.Contains(response, "AT+CSQ") {
		t.Fatalf("unexpected queued response: %q", response)
	}
	if !strings.Contains(backend.Target(), "QModem") {
		t.Fatalf("queue target is not exposed: %q", backend.Target())
	}
}

func TestQModemBackendCloseStopsActiveHelper(t *testing.T) {
	dir := t.TempDir()
	helper := filepath.Join(dir, "qmodem-at")
	started := filepath.Join(dir, "started")
	script := "#!/bin/sh\necho started > \"$STARTED_FILE\"\ntrap 'exit 0' TERM INT\nsleep 30\n"
	if err := os.WriteFile(helper, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("STARTED_FILE", started)
	backend := newQModemQueuedBackend("auto", "/dev/mock-at", helper, time.Second, time.Second)
	done := make(chan error, 1)
	go func() {
		_, err := backend.Execute(context.Background(), "AT")
		done <- err
	}()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Stat(started); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("helper did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	start := time.Now()
	if err := backend.Close(); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("backend close took %s", elapsed)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("active helper did not return after close")
	}
}

func TestLongCommandTimeoutSelection(t *testing.T) {
	regular := 8 * time.Second
	long := 240 * time.Second
	if got := timeoutForATCommand(" AT+COPS=? ", regular, long); got != long {
		t.Fatalf("COPS scan timeout = %s, want %s", got, long)
	}
	if got := timeoutForATCommand("AT+CSQ", regular, long); got != regular {
		t.Fatalf("normal timeout = %s, want %s", got, regular)
	}
}

func TestRotatingLogWriter(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mt5700.log")
	writer, err := openRotatingLog(path, 32, 2)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if _, err := writer.Write([]byte("0123456789abcdef\n")); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path + ".1"); err != nil {
		t.Fatalf("rotated log missing: %v", err)
	}
	if _, err := os.Stat(path + ".3"); !os.IsNotExist(err) {
		t.Fatalf("log backup limit was exceeded: %v", err)
	}
}
