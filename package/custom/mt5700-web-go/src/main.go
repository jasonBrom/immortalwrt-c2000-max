package main

import (
	"bufio"
	"context"
	"crypto/sha1"
	"embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const version = "1.1.0"

//go:embed web
var embeddedWeb embed.FS

type modemInfo struct {
	Section      string `json:"section"`
	Name         string `json:"name"`
	Model        string `json:"model"`
	Manufacturer string `json:"manufacturer"`
	ATPort       string `json:"at_port"`
	Supported    bool   `json:"supported"`
}

type discoveryInfo struct {
	Modems          []modemInfo `json:"modems"`
	Ports           []string    `json:"ports"`
	SelectedSection string      `json:"selected_section"`
	SelectedPort    string      `json:"selected_port"`
	SelectedModel   string      `json:"selected_model"`
	Supported       bool        `json:"supported"`
}

func trimUCIValue(value string) string {
	value = strings.TrimSpace(value)
	if len(value) >= 2 && ((value[0] == '\'' && value[len(value)-1] == '\'') ||
		(value[0] == '"' && value[len(value)-1] == '"')) {
		value = value[1 : len(value)-1]
	}
	return strings.ReplaceAll(value, "'\\''", "'")
}

func mt5700Model(model, manufacturer string) bool {
	identity := strings.ToLower(model + " " + manufacturer)
	return strings.Contains(identity, "mt5700") ||
		(strings.Contains(identity, "td tech") && strings.Contains(identity, "5700"))
}

func discoverModems(requestedSection, requestedPort string) discoveryInfo {
	result := discoveryInfo{Modems: []modemInfo{}, Ports: []string{}}
	output, _ := exec.Command("uci", "-q", "show", "qmodem").Output()
	sections := make(map[string]map[string]string)
	order := make([]string, 0)
	for _, line := range strings.Split(string(output), "\n") {
		if !strings.HasPrefix(line, "qmodem.") {
			continue
		}
		left, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		parts := strings.Split(left, ".")
		if len(parts) != 3 {
			continue
		}
		section, option := parts[1], parts[2]
		if _, exists := sections[section]; !exists {
			sections[section] = make(map[string]string)
			order = append(order, section)
		}
		sections[section][option] = trimUCIValue(value)
	}

	for _, section := range order {
		values := sections[section]
		port := values["override_at_port"]
		if port == "" {
			port = values["at_port"]
		}
		if port == "" {
			continue
		}
		model := values["model"]
		if model == "" {
			model = values["modem_name"]
		}
		name := values["name"]
		if model == "" {
			model = name
		}
		if name == "" {
			name = model
		}
		if name == "" {
			name = section
		}
		info := modemInfo{
			Section: section, Name: name, Model: model,
			Manufacturer: values["manufacturer"], ATPort: port,
		}
		info.Supported = mt5700Model(info.Model, info.Manufacturer)
		result.Modems = append(result.Modems, info)
	}

	portSet := make(map[string]struct{})
	for _, modem := range result.Modems {
		if modem.ATPort != "" {
			portSet[modem.ATPort] = struct{}{}
		}
	}
	for _, pattern := range []string{
		"/dev/ttyUSB*", "/dev/ttyACM*", "/dev/mhi_DUN*", "/dev/wwan*at*",
	} {
		matches, _ := filepath.Glob(pattern)
		for _, match := range matches {
			portSet[match] = struct{}{}
		}
	}
	for port := range portSet {
		result.Ports = append(result.Ports, port)
	}
	sort.Strings(result.Ports)

	selectedSection := requestedSection
	if selectedSection == "" || selectedSection == "auto" {
		if len(result.Modems) > 0 {
			selectedSection = result.Modems[0].Section
		} else {
			selectedSection = "auto"
		}
	}
	result.SelectedSection = selectedSection
	for _, modem := range result.Modems {
		if modem.Section == selectedSection {
			result.SelectedPort = modem.ATPort
			result.SelectedModel = modem.Model
			if result.SelectedModel == "" {
				result.SelectedModel = modem.Name
			}
			result.Supported = modem.Supported
			break
		}
	}
	if requestedPort != "" && requestedPort != "auto" {
		result.SelectedPort = requestedPort
	}
	if result.SelectedPort == "" && len(result.Ports) > 0 {
		result.SelectedPort = result.Ports[0]
	}
	return result
}

type atBackend interface {
	Execute(context.Context, string) (string, error)
	Close() error
	Target() string
}

type inputFlusher interface {
	FlushInput() error
}

type persistentBackend struct {
	kind        string
	target      string
	timeout     time.Duration
	longTimeout time.Duration
	opener      func() (io.ReadWriteCloser, string, error)
	broadcast   func(string)

	commandMu sync.Mutex
	connMu    sync.Mutex
	conn      io.ReadWriteCloser

	stateMu sync.RWMutex
	active  chan []byte
	closed  bool
}

func (b *persistentBackend) Target() string {
	b.stateMu.RLock()
	defer b.stateMu.RUnlock()
	return b.target
}

func (b *persistentBackend) ensureConnection() (io.ReadWriteCloser, error) {
	b.connMu.Lock()
	defer b.connMu.Unlock()
	if b.closed {
		return nil, errors.New("AT 后端已关闭")
	}
	if b.conn != nil {
		return b.conn, nil
	}
	conn, target, err := b.opener()
	if err != nil {
		return nil, err
	}
	b.conn = conn
	b.stateMu.Lock()
	b.target = target
	b.stateMu.Unlock()
	go b.readLoop(conn)
	log.Printf("AT %s 已连接：%s", b.kind, target)
	return conn, nil
}

func (b *persistentBackend) dropConnection(conn io.ReadWriteCloser) {
	b.connMu.Lock()
	if b.conn == conn {
		_ = b.conn.Close()
		b.conn = nil
	}
	b.connMu.Unlock()
}

func (b *persistentBackend) readLoop(conn io.ReadWriteCloser) {
	buffer := make([]byte, 8192)
	for {
		n, err := conn.Read(buffer)
		if n > 0 {
			chunk := append([]byte(nil), buffer[:n]...)
			b.stateMu.RLock()
			active := b.active
			b.stateMu.RUnlock()
			if active != nil {
				select {
				case active <- chunk:
				case <-time.After(500 * time.Millisecond):
					log.Printf("AT 响应缓冲区已满，丢弃 %d 字节", len(chunk))
				}
			} else if b.broadcast != nil {
				b.broadcast(string(chunk))
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, os.ErrClosed) {
				log.Printf("AT %s 读取失败：%v", b.kind, err)
			}
			b.dropConnection(conn)
			return
		}
		if n == 0 {
			time.Sleep(20 * time.Millisecond)
		}
	}
}

func finalATResponse(data []byte) bool {
	normalized := strings.ReplaceAll(string(data), "\r", "")
	for _, line := range strings.Split(normalized, "\n") {
		line = strings.TrimSpace(line)
		if line == "OK" || line == "ERROR" || line == "NO CARRIER" ||
			strings.HasPrefix(line, "+CME ERROR:") || strings.HasPrefix(line, "+CMS ERROR:") {
			return true
		}
	}
	return false
}

func cleanATResponse(command string, data []byte) string {
	normalized := strings.ReplaceAll(string(data), "\x00", "")
	command = strings.TrimSpace(strings.TrimRight(command, "\r\n"))
	lines := strings.Split(strings.ReplaceAll(normalized, "\r\n", "\n"), "\n")
	filtered := make([]string, 0, len(lines))
	removedEcho := false
	for _, line := range lines {
		if !removedEcho && strings.TrimSpace(line) == command {
			removedEcho = true
			continue
		}
		filtered = append(filtered, strings.TrimRight(line, "\r"))
	}
	return strings.TrimSpace(strings.Join(filtered, "\r\n"))
}

func normalizeATCommand(command string) string {
	command = strings.ReplaceAll(command, "\x00", "")
	command = strings.TrimSpace(strings.TrimRight(command, "\r\n"))
	if strings.HasPrefix(command, "AT^SYSCFGEX") {
		command = strings.ReplaceAll(command, "\n", "")
		command = strings.ReplaceAll(command, "\r", "")
		command = strings.ReplaceAll(command, "OK", "")
	}
	return command
}

func timeoutForATCommand(command string, regular, long time.Duration) time.Duration {
	command = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(command), " ", ""))
	if command == "AT+COPS=?" && long > regular {
		return long
	}
	return regular
}

func (b *persistentBackend) Execute(ctx context.Context, command string) (string, error) {
	b.commandMu.Lock()
	defer b.commandMu.Unlock()

	command = normalizeATCommand(command)
	if command == "" {
		return "", errors.New("AT 命令为空")
	}
	if len(command) > 64*1024 {
		return "", errors.New("AT 命令过长")
	}
	conn, err := b.ensureConnection()
	if err != nil {
		return "", err
	}
	if flusher, ok := conn.(inputFlusher); ok {
		_ = flusher.FlushInput()
	}

	responseCh := make(chan []byte, 64)
	b.stateMu.Lock()
	b.active = responseCh
	b.stateMu.Unlock()
	defer func() {
		b.stateMu.Lock()
		if b.active == responseCh {
			b.active = nil
		}
		b.stateMu.Unlock()
	}()

	wireCommand := command
	if !strings.HasSuffix(wireCommand, "\r") {
		wireCommand += "\r"
	}
	if _, err := conn.Write([]byte(wireCommand)); err != nil {
		b.dropConnection(conn)
		return "", fmt.Errorf("写入 AT 端口失败：%w", err)
	}

	timeout := timeoutForATCommand(command, b.timeout, b.longTimeout)
	if timeout <= 0 {
		timeout = 8 * time.Second
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	var response []byte
	for {
		select {
		case chunk := <-responseCh:
			response = append(response, chunk...)
			if len(response) > 2*1024*1024 {
				return "", errors.New("AT 响应超过 2 MiB 限制")
			}
			if finalATResponse(response) {
				return cleanATResponse(command, response), nil
			}
		case <-timer.C:
			if len(response) > 0 {
				return cleanATResponse(command, response), fmt.Errorf("AT 响应超时（收到不完整数据）")
			}
			return "", errors.New("AT 响应超时")
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
}

func (b *persistentBackend) Close() error {
	b.connMu.Lock()
	defer b.connMu.Unlock()
	b.closed = true
	if b.conn != nil {
		err := b.conn.Close()
		b.conn = nil
		return err
	}
	return nil
}

type qmodemQueuedBackend struct {
	section        string
	configuredPort string
	helper         string
	timeout        time.Duration
	longTimeout    time.Duration
	gate           chan struct{}
	closeCh        chan struct{}

	stateMu sync.RWMutex
	target  string
	closed  bool
	active  sync.WaitGroup
}

func newQModemQueuedBackend(section, configuredPort, helper string, timeout, longTimeout time.Duration) *qmodemQueuedBackend {
	return &qmodemQueuedBackend{
		section: section, configuredPort: configuredPort, helper: helper,
		timeout: timeout, longTimeout: longTimeout, gate: make(chan struct{}, 1),
		closeCh: make(chan struct{}),
	}
}

func (b *qmodemQueuedBackend) Target() string {
	b.stateMu.RLock()
	defer b.stateMu.RUnlock()
	if b.target == "" {
		return "QModem AT 队列（等待发现模组）"
	}
	return b.target
}

func (b *qmodemQueuedBackend) Execute(ctx context.Context, command string) (string, error) {
	command = normalizeATCommand(command)
	if command == "" {
		return "", errors.New("AT 命令为空")
	}
	if len(command) > 64*1024 {
		return "", errors.New("AT 命令过长")
	}
	select {
	case b.gate <- struct{}{}:
		defer func() { <-b.gate }()
	case <-ctx.Done():
		return "", fmt.Errorf("等待 5700 面板 AT 队列超时：%w", ctx.Err())
	case <-b.closeCh:
		return "", errors.New("AT 后端已关闭")
	}

	b.stateMu.Lock()
	if b.closed {
		b.stateMu.Unlock()
		return "", errors.New("AT 后端已关闭")
	}
	b.active.Add(1)
	b.stateMu.Unlock()
	defer b.active.Done()
	discovery := discoverModems(b.section, b.configuredPort)
	port := discovery.SelectedPort
	if b.configuredPort != "" && b.configuredPort != "auto" {
		port = b.configuredPort
	}
	if port == "" {
		return "", errors.New("QModem 尚未发现可用 AT 串口，请在 LuCI 中手动选择")
	}
	b.stateMu.Lock()
	b.target = port + "（QModem 串行队列）"
	b.stateMu.Unlock()

	timeout := timeoutForATCommand(command, b.timeout, b.longTimeout)
	seconds := int((timeout + time.Second - 1) / time.Second)
	if seconds < 1 {
		seconds = 1
	}
	commandCtx, cancel := context.WithCancel(ctx)
	closedWatchDone := make(chan struct{})
	go func() {
		select {
		case <-b.closeCh:
			cancel()
		case <-closedWatchDone:
		}
	}()
	defer func() {
		close(closedWatchDone)
		cancel()
	}()
	cmd := exec.CommandContext(commandCtx, b.helper, port, strconv.Itoa(seconds), command)
	// The helper contains lock-owning shell children. Terminate the process
	// group so procd restart cannot leave a queued AT request running behind the
	// new panel process; shell EXIT traps still get SIGTERM and release locks.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return os.ErrProcessDone
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
	cmd.WaitDelay = 3 * time.Second
	output, err := cmd.CombinedOutput()
	if len(output) > 2*1024*1024 {
		return "", errors.New("AT 响应超过 2 MiB 限制")
	}
	cleaned := cleanATResponse(command, output)
	if err != nil {
		// Modem-level ERROR/CME/CMS is a valid completed transaction and is
		// reported to the browser as an AT error, not a broken queue.
		if finalATResponse(output) {
			return cleaned, nil
		}
		if cleaned != "" {
			return "", fmt.Errorf("QModem AT 队列失败：%w：%s", err, cleaned)
		}
		return "", fmt.Errorf("QModem AT 队列失败：%w", err)
	}
	return cleaned, nil
}

func (b *qmodemQueuedBackend) Close() error {
	b.stateMu.Lock()
	if !b.closed {
		b.closed = true
		close(b.closeCh)
	}
	b.stateMu.Unlock()
	b.active.Wait()
	return nil
}

func newNetworkBackend(host string, port int, timeout, longTimeout time.Duration, broadcast func(string)) *persistentBackend {
	target := net.JoinHostPort(host, strconv.Itoa(port))
	backend := &persistentBackend{kind: "网络", target: target, timeout: timeout, longTimeout: longTimeout, broadcast: broadcast}
	backend.opener = func() (io.ReadWriteCloser, string, error) {
		conn, err := net.DialTimeout("tcp", target, timeout)
		if err != nil {
			return nil, target, fmt.Errorf("连接网络 AT %s 失败：%w", target, err)
		}
		return conn, target, nil
	}
	return backend
}

type wsClient struct {
	conn net.Conn
	rw   *bufio.ReadWriter
	mu   sync.Mutex
}

func (c *wsClient) writeFrame(opcode byte, payload []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	header := []byte{0x80 | opcode}
	switch {
	case len(payload) < 126:
		header = append(header, byte(len(payload)))
	case len(payload) <= 65535:
		header = append(header, 126, 0, 0)
		binary.BigEndian.PutUint16(header[len(header)-2:], uint16(len(payload)))
	default:
		header = append(header, 127, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(header[len(header)-8:], uint64(len(payload)))
	}
	if _, err := c.rw.Write(header); err != nil {
		return err
	}
	if _, err := c.rw.Write(payload); err != nil {
		return err
	}
	return c.rw.Flush()
}

func (c *wsClient) writeText(text string) error {
	return c.writeFrame(0x1, []byte(text))
}

func (c *wsClient) readFrame() (bool, byte, []byte, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(c.rw, header); err != nil {
		return false, 0, nil, err
	}
	fin := header[0]&0x80 != 0
	opcode := header[0] & 0x0f
	masked := header[1]&0x80 != 0
	length := uint64(header[1] & 0x7f)
	if length == 126 {
		extra := make([]byte, 2)
		if _, err := io.ReadFull(c.rw, extra); err != nil {
			return false, 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(extra))
	} else if length == 127 {
		extra := make([]byte, 8)
		if _, err := io.ReadFull(c.rw, extra); err != nil {
			return false, 0, nil, err
		}
		length = binary.BigEndian.Uint64(extra)
	}
	if !masked {
		return false, 0, nil, errors.New("客户端 WebSocket 帧未掩码")
	}
	if length > 2*1024*1024 {
		return false, 0, nil, errors.New("WebSocket 消息超过 2 MiB 限制")
	}
	mask := make([]byte, 4)
	if _, err := io.ReadFull(c.rw, mask); err != nil {
		return false, 0, nil, err
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(c.rw, payload); err != nil {
		return false, 0, nil, err
	}
	for index := range payload {
		payload[index] ^= mask[index%4]
	}
	return fin, opcode, payload, nil
}

type wsHub struct {
	mu      sync.RWMutex
	clients map[*wsClient]struct{}
	limit   int
}

func newHub(limit int) *wsHub {
	return &wsHub{clients: make(map[*wsClient]struct{}), limit: limit}
}

func (h *wsHub) add(client *wsClient) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.limit > 0 && len(h.clients) >= h.limit {
		return false
	}
	h.clients[client] = struct{}{}
	return true
}

func (h *wsHub) remove(client *wsClient) {
	h.mu.Lock()
	delete(h.clients, client)
	h.mu.Unlock()
	_ = client.conn.Close()
}

func (h *wsHub) count() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

func (h *wsHub) broadcastRaw(data string) {
	data = strings.TrimSpace(strings.ReplaceAll(data, "\x00", ""))
	if data == "" {
		return
	}
	payload, _ := json.Marshal(map[string]any{"type": "raw_data", "data": data})
	h.mu.RLock()
	clients := make([]*wsClient, 0, len(h.clients))
	for client := range h.clients {
		clients = append(clients, client)
	}
	h.mu.RUnlock()
	for _, client := range clients {
		if err := client.writeText(string(payload)); err != nil {
			h.remove(client)
		}
	}
}

type serverConfig struct {
	Listen        string
	Transport     string
	Section       string
	SerialPort    string
	Baud          int
	NetworkHost   string
	NetworkPort   int
	Timeout       time.Duration
	LongTimeout   time.Duration
	QueueTimeout  time.Duration
	WSIdleTimeout time.Duration
	LogFile       string
	Model         string
	Manufacturer  string
}

type webApp struct {
	config  serverConfig
	hub     *wsHub
	backend atBackend
	web     http.Handler
}

func websocketRequest(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("Upgrade"), "websocket") &&
		strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade")
}

func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil {
		return false
	}
	originHost := strings.Trim(strings.ToLower(parsed.Hostname()), "[]")
	requestHost := r.Host
	if host, _, err := net.SplitHostPort(r.Host); err == nil {
		requestHost = host
	}
	requestHost = strings.Trim(strings.ToLower(requestHost), "[]")
	return originHost == requestHost
}

func websocketAccept(key string) string {
	digest := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(digest[:])
}

func (a *webApp) upgradeWebSocket(w http.ResponseWriter, r *http.Request) {
	if !sameOrigin(r) {
		http.Error(w, "WebSocket Origin 不匹配", http.StatusForbidden)
		return
	}
	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	if key == "" || r.Header.Get("Sec-WebSocket-Version") != "13" {
		http.Error(w, "无效的 WebSocket 握手", http.StatusBadRequest)
		return
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "当前 HTTP 服务不支持 WebSocket", http.StatusInternalServerError)
		return
	}
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return
	}
	client := &wsClient{conn: conn, rw: rw}
	if !a.hub.add(client) {
		_, _ = rw.WriteString("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n")
		_ = rw.Flush()
		_ = conn.Close()
		return
	}
	_, _ = rw.WriteString("HTTP/1.1 101 Switching Protocols\r\n")
	_, _ = rw.WriteString("Upgrade: websocket\r\n")
	_, _ = rw.WriteString("Connection: Upgrade\r\n")
	_, _ = rw.WriteString("Sec-WebSocket-Accept: " + websocketAccept(key) + "\r\n\r\n")
	if err := rw.Flush(); err != nil {
		a.hub.remove(client)
		return
	}
	go a.serveWebSocket(client)
}

type atResponse struct {
	Success bool   `json:"success"`
	Data    string `json:"data,omitempty"`
	Error   string `json:"error,omitempty"`
}

func atResponseIsError(response string) bool {
	upper := strings.ToUpper(response)
	return strings.Contains(upper, "\r\nERROR") || strings.HasPrefix(upper, "ERROR") ||
		strings.Contains(upper, "+CME ERROR:") || strings.Contains(upper, "+CMS ERROR:") ||
		strings.Contains(upper, "NO CARRIER")
}

func (a *webApp) commandTimeout(command string) time.Duration {
	return timeoutForATCommand(command, a.config.Timeout, a.config.LongTimeout)
}

func (a *webApp) handleATCommand(client *wsClient, command string) {
	if command == "ping" {
		_ = client.writeText("pong")
		return
	}
	command = normalizeATCommand(command)
	response := atResponse{}
	if command == "AT+CONNECT?" {
		kind := "1"
		if a.config.Transport == "network" {
			kind = "0"
		}
		response.Success = true
		response.Data = "+CONNECT: " + kind + "\r\nOK"
	} else {
		deadline := a.commandTimeout(command) + a.config.QueueTimeout + 2*time.Second
		ctx, cancel := context.WithTimeout(context.Background(), deadline)
		data, err := a.backend.Execute(ctx, command)
		cancel()
		if err != nil {
			response.Error = err.Error()
		} else if atResponseIsError(data) {
			response.Error = data
		} else {
			response.Success = true
			response.Data = data
		}
	}
	payload, _ := json.Marshal(response)
	_ = client.writeText(string(payload))
}

func (a *webApp) serveWebSocket(client *wsClient) {
	defer a.hub.remove(client)
	var fragmented []byte
	var fragmentOpcode byte
	for {
		if a.config.WSIdleTimeout > 0 {
			_ = client.conn.SetReadDeadline(time.Now().Add(a.config.WSIdleTimeout))
		}
		fin, opcode, payload, err := client.readFrame()
		if err != nil {
			return
		}
		switch opcode {
		case 0x8:
			_ = client.writeFrame(0x8, payload)
			return
		case 0x9:
			_ = client.writeFrame(0xA, payload)
			continue
		case 0xA:
			continue
		case 0x1, 0x2:
			if fin {
				if opcode == 0x1 {
					a.handleATCommand(client, string(payload))
				}
				continue
			}
			fragmentOpcode = opcode
			fragmented = append(fragmented[:0], payload...)
		case 0x0:
			fragmented = append(fragmented, payload...)
			if len(fragmented) > 2*1024*1024 {
				return
			}
			if fin {
				if fragmentOpcode == 0x1 {
					a.handleATCommand(client, string(fragmented))
				}
				fragmented = nil
				fragmentOpcode = 0
			}
		default:
			return
		}
	}
}

func hostWithoutPort(hostport string) string {
	if host, _, err := net.SplitHostPort(hostport); err == nil {
		return strings.Trim(host, "[]")
	}
	if strings.HasPrefix(hostport, "[") && strings.Contains(hostport, "]") {
		return strings.Trim(strings.Split(hostport, "]")[0], "[]")
	}
	if strings.Count(hostport, ":") == 1 {
		return strings.Split(hostport, ":")[0]
	}
	return strings.Trim(hostport, "[]")
}

func listenPort(listen string) int {
	_, port, err := net.SplitHostPort(listen)
	if err != nil {
		return 9010
	}
	value, err := strconv.Atoi(port)
	if err != nil {
		return 9010
	}
	return value
}

func (a *webApp) wsInfo(w http.ResponseWriter, r *http.Request) {
	host := hostWithoutPort(r.Host)
	port := listenPort(a.config.Listen)
	displayHost := host
	if strings.Contains(host, ":") {
		displayHost = "[" + host + "]"
	}
	response := map[string]any{
		"success": true,
		"data": map[string]any{
			"host": host, "port": port, "allow_wan": 0,
			"require_auth": false,
			"ws_url":       fmt.Sprintf("ws://%s:%d", displayHost, port),
			"timestamp":    time.Now().Unix(),
		},
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(response)
}

func (a *webApp) configJSON(w http.ResponseWriter, r *http.Request) {
	host := hostWithoutPort(r.Host)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"at":     map[string]any{"host": host, "port": listenPort(a.config.Listen)},
		"status": "true", "require_auth": false,
	})
}

func (a *webApp) health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok": true, "service": "mt5700-web-go", "version": version,
		"transport": a.config.Transport, "target": a.backend.Target(),
		"model": a.config.Model, "manufacturer": a.config.Manufacturer,
		"supported":         mt5700Model(a.config.Model, a.config.Manufacturer),
		"websocket_clients": a.hub.count(),
	})
}

func (a *webApp) clearLog(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if a.config.LogFile == "" {
		_ = json.NewEncoder(w).Encode(map[string]any{"success": false, "error": "未配置日志文件"})
		return
	}
	if err := os.Truncate(a.config.LogFile, 0); err != nil {
		_ = json.NewEncoder(w).Encode(map[string]any{"success": false, "error": err.Error()})
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"success": true, "message": "日志已清空"})
}

func (a *webApp) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "same-origin")
	if websocketRequest(r) {
		a.upgradeWebSocket(w, r)
		return
	}
	switch r.URL.Path {
	case "/":
		http.Redirect(w, r, "/5700/", http.StatusFound)
		return
	case "/cgi-bin/at-ws-info":
		a.wsInfo(w, r)
		return
	case "/cgi-bin/at-log-clear":
		a.clearLog(w, r)
		return
	case "/5700/config.json":
		a.configJSON(w, r)
		return
	case "/healthz":
		a.health(w, r)
		return
	case "/scripts/loading.js":
		data, err := fs.ReadFile(embeddedWeb, "web/scripts/loading.js")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		_, _ = w.Write(data)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/5700/") {
		if strings.HasSuffix(r.URL.Path, "/") || strings.HasSuffix(r.URL.Path, "/index.html") {
			w.Header().Set("Cache-Control", "no-cache")
		} else {
			w.Header().Set("Cache-Control", "public, max-age=604800")
		}
		a.web.ServeHTTP(w, r)
		return
	}
	http.NotFound(w, r)
}

type rotatingLogWriter struct {
	mu      sync.Mutex
	path    string
	maxSize int64
	backups int
	file    *os.File
}

func openRotatingLog(path string, maxSize int64, backups int) (*rotatingLogWriter, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0640)
	if err != nil {
		return nil, err
	}
	return &rotatingLogWriter{path: path, maxSize: maxSize, backups: backups, file: file}, nil
}

func (w *rotatingLogWriter) rotateLocked() error {
	if w.file != nil {
		_ = w.file.Close()
		w.file = nil
	}
	if w.backups > 0 {
		_ = os.Remove(fmt.Sprintf("%s.%d", w.path, w.backups))
		for index := w.backups - 1; index >= 1; index-- {
			_ = os.Rename(fmt.Sprintf("%s.%d", w.path, index), fmt.Sprintf("%s.%d", w.path, index+1))
		}
		_ = os.Rename(w.path, w.path+".1")
	} else {
		_ = os.Remove(w.path)
	}
	file, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0640)
	if err != nil {
		return err
	}
	w.file = file
	return nil
}

func (w *rotatingLogWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return 0, os.ErrClosed
	}
	if w.maxSize > 0 {
		if info, err := w.file.Stat(); err == nil && info.Size()+int64(len(data)) > w.maxSize {
			if err := w.rotateLocked(); err != nil {
				return 0, err
			}
		}
	}
	return w.file.Write(data)
}

func (w *rotatingLogWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return nil
	}
	err := w.file.Close()
	w.file = nil
	return err
}

func setupLogger(path string, maxSize int64, backups int) func() {
	if path == "" {
		return func() {}
	}
	file, err := openRotatingLog(path, maxSize, backups)
	if err != nil {
		log.Printf("无法打开日志文件 %s：%v", path, err)
		return func() {}
	}
	log.SetOutput(io.MultiWriter(os.Stdout, file))
	return func() { _ = file.Close() }
}

func main() {
	listen := flag.String("listen", "0.0.0.0:9010", "HTTP 与 WebSocket 监听地址")
	transport := flag.String("transport", "serial", "AT 连接类型：serial 或 network")
	section := flag.String("modem-section", "auto", "QModem 配置节")
	serialPort := flag.String("serial", "auto", "AT 串口")
	baud := flag.Int("baud", 115200, "串口波特率")
	networkHost := flag.String("network-host", "192.168.8.1", "网络 AT 主机")
	networkPort := flag.Int("network-port", 20249, "网络 AT 端口")
	timeout := flag.Duration("timeout", 8*time.Second, "AT 命令超时")
	longTimeout := flag.Duration("long-timeout", 240*time.Second, "AT+COPS=? 等长命令超时")
	queueTimeout := flag.Duration("queue-timeout", 60*time.Second, "等待 QModem AT 队列超时")
	wsIdleTimeout := flag.Duration("ws-idle-timeout", 5*time.Minute, "空闲 WebSocket 清理时间")
	qmodemHelper := flag.String("qmodem-helper", "/usr/libexec/mt5700-web/qmodem-at", "QModem AT 队列助手")
	logFile := flag.String("log-file", "/var/log/mt5700-web.log", "日志文件")
	logMaxBytes := flag.Int64("log-max-bytes", 2*1024*1024, "单个日志文件最大字节数")
	logBackups := flag.Int("log-backups", 3, "轮转日志保留份数")
	maxClients := flag.Int("max-clients", 8, "最大 WebSocket 客户端数")
	discover := flag.Bool("discover", false, "输出 QModem 与串口发现结果")
	showVersion := flag.Bool("version", false, "输出版本")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}
	discovery := discoverModems(*section, *serialPort)
	if *discover {
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(discovery); err != nil {
			log.Fatal(err)
		}
		return
	}
	if *logMaxBytes < 64*1024 {
		*logMaxBytes = 64 * 1024
	}
	if *logBackups < 0 {
		*logBackups = 0
	}
	closeLog := setupLogger(*logFile, *logMaxBytes, *logBackups)
	defer closeLog()
	if *timeout < 500*time.Millisecond {
		*timeout = 500 * time.Millisecond
	}
	if *longTimeout < *timeout {
		*longTimeout = *timeout
	}
	if *queueTimeout < time.Second {
		*queueTimeout = time.Second
	}
	if *wsIdleTimeout < 30*time.Second {
		*wsIdleTimeout = 30 * time.Second
	}
	if *transport != "serial" && *transport != "network" {
		log.Fatalf("不支持的 AT 连接类型：%s", *transport)
	}

	webRoot, err := fs.Sub(embeddedWeb, "web")
	if err != nil {
		log.Fatal(err)
	}
	hub := newHub(*maxClients)
	var backend atBackend
	if *transport == "network" {
		backend = newNetworkBackend(*networkHost, *networkPort, *timeout, *longTimeout, hub.broadcastRaw)
	} else {
		backend = newQModemQueuedBackend(*section, *serialPort, *qmodemHelper, *timeout, *longTimeout)
	}
	defer backend.Close()
	config := serverConfig{
		Listen: *listen, Transport: *transport, Section: *section,
		SerialPort: *serialPort, Baud: *baud,
		NetworkHost: *networkHost, NetworkPort: *networkPort,
		Timeout: *timeout, LongTimeout: *longTimeout, QueueTimeout: *queueTimeout,
		WSIdleTimeout: *wsIdleTimeout, LogFile: *logFile,
		Model: discovery.SelectedModel,
	}
	for _, modem := range discovery.Modems {
		if modem.Section == discovery.SelectedSection {
			config.Manufacturer = modem.Manufacturer
			break
		}
	}
	app := &webApp{
		config: config, hub: hub, backend: backend,
		web: http.StripPrefix("/5700/", http.FileServer(http.FS(webRoot))),
	}
	server := &http.Server{
		Addr: *listen, Handler: app,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    32 * 1024,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	transportLabel := *transport
	if *transport == "serial" {
		transportLabel = "QModem 串行队列"
	}
	log.Printf("MT5700 Web 控制面板 %s 已监听 %s，AT=%s", version, *listen, transportLabel)
	if config.Model != "" && !mt5700Model(config.Model, config.Manufacturer) {
		log.Printf("警告：QModem 当前模组 %q 不是已验证的 MT5700 系列", config.Model)
	}
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
