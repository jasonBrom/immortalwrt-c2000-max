package main

import (
	"bufio"
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	mrand "math/rand"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	appPkg     = "com.cnspeedtest.globalspeed"
	defaultIP  = "111.8.9.157"
	defaultTCP = 65499
	boundary   = "00content0boundary00"
	downloadUA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/100.0.4896.60 Safari/537.36"
	uploadUA         = "Dalvik/1.6.0 (Linux; U; Android 4.2.2; GT-I9505 Build/JDQ39)"
	defaultAndroidUA = "Dalvik/2.1.0 (Linux; U; Android 13; OpenWrtSpeed Build/HAR)"
)

type node struct {
	Host        string `json:"host"`
	Port        int    `json:"port"`
	Name        string `json:"name"`
	ID          string `json:"hostid,omitempty"`
	Province    string `json:"province,omitempty"`
	City        string `json:"city,omitempty"`
	Operator    string `json:"operator,omitempty"`
	Source      string `json:"source,omitempty"`
	Recommended bool   `json:"recommended"`
}

type nodeChoice struct {
	Node      node
	Latencies []float64
	Index     int
}

type speedResult struct {
	Bytes    int64
	Elapsed  float64
	AvgMbps  float64
	PeakMbps float64
	Errors   int64
}

type speedSample struct {
	T      float64 `json:"t"`
	Mbps   float64 `json:"mbps"`
	Bytes  int64   `json:"bytes"`
	Phase  string  `json:"phase"`
	Avg    float64 `json:"avg"`
	Peak   float64 `json:"peak"`
	Errors int64   `json:"errors"`
}

type counters struct {
	bytes     atomic.Int64
	errors    atomic.Int64
	reconnect atomic.Int64
}

type options struct {
	Web               bool
	Listen            string
	Auto              bool
	Host              string
	Port              int
	ManualName        string
	Duration          time.Duration
	Bandwidth         int
	DownloadThreads   int
	UploadThreads     int
	ProbeCount        int
	PingCount         int
	ConnectTimeout    time.Duration
	RunDownload       bool
	RunUpload         bool
	UploadContentLen  int64
	JSON              bool
	NoDownloadProbe   bool
	ForceDownload     bool
	InsecureDiscovery bool
	IMEI              string
	AndroidUA         string
	MachineID         string
	Context           context.Context
	Progress          func(phase string, sample speedSample)
}

func main() {
	var o options
	flag.BoolVar(&o.Web, "web", true, "start web UI server")
	flag.StringVar(&o.Listen, "listen", "0.0.0.0:8787", "web listen address")
	flag.BoolVar(&o.Auto, "auto", true, "auto discover nearest nodes")
	flag.StringVar(&o.Host, "host", defaultIP, "manual node host")
	flag.IntVar(&o.Port, "port", defaultTCP, "manual node port")
	flag.StringVar(&o.ManualName, "manual-name", "manual", "manual node display name")
	flag.DurationVar(&o.Duration, "duration", 15*time.Second, "download/upload duration, for example 15s")
	flag.IntVar(&o.Bandwidth, "bandwidth", 2000, "dovalid bandwidth parameter")
	flag.IntVar(&o.DownloadThreads, "download-threads", 16, "download workers")
	flag.IntVar(&o.UploadThreads, "upload-threads", 8, "upload workers")
	flag.IntVar(&o.ProbeCount, "probe-count", 10, "auto node candidates to probe")
	flag.IntVar(&o.PingCount, "ping-count", 4, "TCP ping count before speed test")
	flag.DurationVar(&o.ConnectTimeout, "connect-timeout", time.Second, "TCP connect timeout")
	flag.BoolVar(&o.RunDownload, "download", true, "run download test")
	flag.BoolVar(&o.RunUpload, "upload", true, "run upload test")
	flag.Int64Var(&o.UploadContentLen, "upload-content-length", 900000000, "upload Content-Length")
	flag.BoolVar(&o.JSON, "json", false, "print final result as JSON")
	flag.BoolVar(&o.NoDownloadProbe, "no-download-probe", false, "skip small download probe")
	flag.BoolVar(&o.ForceDownload, "force-download", false, "run download even if probe fails")
	flag.BoolVar(&o.InsecureDiscovery, "insecure-discovery", true, "skip TLS verification for discovery endpoint")
	flag.StringVar(&o.IMEI, "imei", "", "manual TS imei; default random")
	flag.StringVar(&o.AndroidUA, "android-ua", defaultAndroidUA, "Android User-Agent used by discovery and dovalid requests")
	flag.StringVar(&o.MachineID, "machine-id", "", "stable machine id for cloud statistics")
	flag.Parse()

	if o.Duration <= 0 {
		o.Duration = 15 * time.Second
	}
	if o.IMEI == "" {
		o.IMEI = randomTSIMEI()
	}
	if o.AndroidUA == "" {
		o.AndroidUA = defaultAndroidUA
	}
	if o.MachineID == "" {
		o.MachineID = md5Hex("machine|" + o.IMEI)[:24]
	}

	if o.Web {
		if err := startWeb(o); err != nil {
			fatal(err)
		}
		return
	}

	result, err := runCLI(o)
	if err != nil {
		fatal(err)
	}
	if o.JSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(result)
	}
}

func runCLI(o options) (map[string]any, error) {
	result := map[string]any{"imei": o.IMEI, "android_ua": o.AndroidUA, "machine_id": o.MachineID}
	choice, err := chooseNode(o)
	if err != nil {
		return nil, err
	}
	result["node"] = choice.Node
	result["latency_ms"] = latencySummary(choice.Latencies)

	if !o.JSON {
		fmt.Printf("节点：%s  %s:%d\n", displayName(choice.Node), choice.Node.Host, choice.Node.Port)
		fmt.Printf("TCP Ping：%s\n", formatLatency(choice.Latencies))
	}

	key, ts, err := dovalid(choice.Node.Host, choice.Node.Port, o.Bandwidth, o.IMEI, o.AndroidUA, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dovalid failed: %w", err)
	}
	if !o.JSON {
		fmt.Println("dovalid：OK")
	}

	if o.RunDownload {
		if !o.NoDownloadProbe {
			ok := downloadProbe(choice.Node, key, ts, 5*time.Second)
			if !ok && !o.ForceDownload {
				return nil, fmt.Errorf("download probe failed; use --force-download to continue")
			}
		}
		res := measureDownload(choice.Node, key, ts, o)
		result["download"] = res
		if !o.JSON {
			fmt.Printf("\n下载：平均 %.2f Mbps  峰值 %.2f Mbps  流量 %.2f MB\n", res.AvgMbps, res.PeakMbps, float64(res.Bytes)/1024/1024)
		}
	}

	if o.RunUpload {
		_ = preUploadPost(choice.Node, key, o.AndroidUA, 5*time.Second)
		res := measureUpload(choice.Node, key, o)
		result["upload"] = res
		if !o.JSON {
			fmt.Printf("\n上传：平均 %.2f Mbps  峰值 %.2f Mbps  流量 %.2f MB\n", res.AvgMbps, res.PeakMbps, float64(res.Bytes)/1024/1024)
		}
	}

	return result, nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "ERROR:", err)
	os.Exit(1)
}

func md5Hex(s string) string {
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

func token(imei string, ts int64, bandwidth int) string {
	part1 := md5Hex("model=Android&imei=" + imei)
	part2 := md5Hex(fmt.Sprintf("stime=%d&band=%d&rand=12345555", ts, bandwidth))
	return md5Hex(part1 + part2)
}

func randomTSIMEI() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		mrand.Seed(time.Now().UnixNano())
		for i := range b {
			b[i] = byte(mrand.Intn(256))
		}
	}
	return "TS" + strings.ToUpper(hex.EncodeToString(b))
}

func httpClient(timeout time.Duration, insecure bool) *http.Client {
	tr := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   timeout,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout: timeout,
		TLSClientConfig:     &tls.Config{InsecureSkipVerify: insecure}, // OpenWrt boxes often lack CA bundles.
	}
	return &http.Client{Timeout: timeout, Transport: tr}
}

func getServerTime(timeout time.Duration) int64 {
	req, _ := http.NewRequest("GET", "http://dlc.duoweisoft.com:8096/dataServer/time.php", nil)
	req.Header.Set("User-Agent", "Mozilla/5.0")
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := httpClient(timeout, false).Do(req)
	if err != nil {
		return time.Now().Unix()
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	if err != nil {
		return time.Now().Unix()
	}
	ts, err := strconv.ParseInt(strings.TrimSpace(string(body)), 10, 64)
	if err != nil {
		return time.Now().Unix()
	}
	return ts
}

func mappingString(item map[string]any, keys ...string) string {
	for _, key := range keys {
		value, ok := item[key]
		if !ok || value == nil {
			continue
		}
		text := strings.TrimSpace(fmt.Sprint(value))
		if text != "" && text != "<nil>" {
			return text
		}
	}
	return ""
}

func mappingPort(item map[string]any) int {
	value := mappingString(item, "port")
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return defaultTCP
	}
	return port
}

func nodeFromMapping(item map[string]any, source string, recommended bool) (node, bool) {
	host := mappingString(item, "host", "hostip")
	if host == "" {
		return node{}, false
	}
	port := mappingPort(item)
	name := mappingString(item, "name", "hostname")
	province := mappingString(item, "province", "pname")
	city := mappingString(item, "city", "location")
	operator := mappingString(item, "operator", "oper")
	if name == "" {
		name = strings.TrimSpace(city + operator)
	}
	if name == "" {
		name = net.JoinHostPort(host, strconv.Itoa(port))
	}
	return node{
		Host:        host,
		Port:        port,
		Name:        name,
		ID:          mappingString(item, "hostid", "hostId"),
		Province:    province,
		City:        city,
		Operator:    operator,
		Source:      source,
		Recommended: recommended,
	}, true
}

func discoverNodes(o options) ([]node, error) {
	req, _ := http.NewRequest("GET", "https://dlcv2.cnspeedtest.cn:8443/dataServer/getIpLocSP.php", nil)
	req.Header.Set("User-Agent", o.AndroidUA)
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := httpClient(5*time.Second, o.InsecureDiscovery).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimSpace(string(body)), "|")
	if len(parts) < 2 {
		return nil, fmt.Errorf("unexpected getIpLocSP response")
	}
	publicIP := parts[0]
	var loc []string
	_ = json.Unmarshal([]byte(parts[1]), &loc)
	province, city, carrier := "", "", ""
	if len(loc) > 1 {
		province = loc[1]
	}
	if len(loc) > 2 {
		city = loc[2]
	}
	if len(parts) > 3 {
		carrier = parts[3]
	} else if len(loc) > 4 {
		carrier = loc[4]
	}
	if province != "" && !strings.HasSuffix(province, "省") && !strings.HasSuffix(province, "市") && !strings.HasSuffix(province, "自治区") {
		province += "省"
	}
	if city != "" && !strings.HasSuffix(city, "市") && !strings.HasSuffix(city, "地区") && !strings.HasSuffix(city, "自治州") {
		city += "市"
	}

	q := url.Values{}
	q.Set("ip", publicIP)
	q.Set("network", "4")
	q.Set("province", province)
	q.Set("city", city)
	q.Set("wifioper", carrier)
	q.Set("mobileoperid", "46001")
	q.Set("ipv6", "0")
	q.Set("model", "Android")
	q.Set("pkg", appPkg)
	req, _ = http.NewRequest("GET", "http://dlc.duoweisoft.com:8096/dataServer/mobilematch_many.php?"+q.Encode(), nil)
	req.Header.Set("User-Agent", o.AndroidUA)
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err = httpClient(5*time.Second, false).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var raw []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, err
	}
	nodes := make([]node, 0, len(raw))
	for _, item := range raw {
		n, ok := nodeFromMapping(item, "recommended", true)
		if !ok {
			continue
		}
		if n.Province == "" {
			n.Province = province
		}
		if n.City == "" {
			n.City = city
		}
		if n.Operator == "" {
			n.Operator = carrier
		}
		nodes = append(nodes, n)
	}
	return nodes, nil
}

func chooseNode(o options) (nodeChoice, error) {
	if !o.Auto {
		name := strings.TrimSpace(o.ManualName)
		if name == "" {
			name = "manual"
		}
		n := node{Host: o.Host, Port: o.Port, Name: name, Source: "manual"}
		return nodeChoice{Node: n, Latencies: tcpPing(n, o.PingCount, o.ConnectTimeout), Index: 1}, nil
	}
	nodes, err := discoverNodes(o)
	if err != nil || len(nodes) == 0 {
		n := node{Host: o.Host, Port: o.Port, Name: "fallback"}
		return nodeChoice{Node: n, Latencies: tcpPing(n, o.PingCount, o.ConnectTimeout), Index: 1}, nil
	}
	limit := o.ProbeCount
	if limit <= 0 || limit > len(nodes) {
		limit = len(nodes)
	}
	choices := make([]nodeChoice, 0, limit)
	for i, n := range nodes[:limit] {
		lats := tcpPing(n, o.PingCount, o.ConnectTimeout)
		if finiteCount(lats) > 0 {
			choices = append(choices, nodeChoice{Node: n, Latencies: lats, Index: i + 1})
		}
	}
	if len(choices) == 0 {
		return nodeChoice{}, fmt.Errorf("all candidate nodes unreachable")
	}
	sort.SliceStable(choices, func(i, j int) bool {
		return avgLatency(choices[i].Latencies) < avgLatency(choices[j].Latencies)
	})
	return choices[0], nil
}

func tcpPing(n node, count int, timeout time.Duration) []float64 {
	out := make([]float64, 0, count)
	address := net.JoinHostPort(n.Host, strconv.Itoa(n.Port))
	for i := 0; i < count; i++ {
		start := time.Now()
		conn, err := net.DialTimeout("tcp", address, timeout)
		if err != nil {
			out = append(out, math.NaN())
		} else {
			_ = conn.Close()
			out = append(out, float64(time.Since(start).Microseconds())/1000)
		}
		time.Sleep(80 * time.Millisecond)
	}
	return out
}

func finiteCount(v []float64) int {
	n := 0
	for _, x := range v {
		if !math.IsNaN(x) && !math.IsInf(x, 0) {
			n++
		}
	}
	return n
}

func avgLatency(v []float64) float64 {
	sum, n := 0.0, 0
	for _, x := range v {
		if !math.IsNaN(x) && !math.IsInf(x, 0) {
			sum += x
			n++
		}
	}
	if n == 0 {
		return math.Inf(1)
	}
	return sum / float64(n)
}

func latencySummary(v []float64) map[string]float64 {
	ok := make([]float64, 0, len(v))
	for _, x := range v {
		if !math.IsNaN(x) && !math.IsInf(x, 0) {
			ok = append(ok, x)
		}
	}
	if len(ok) == 0 {
		return nil
	}
	sort.Float64s(ok)
	sum := 0.0
	for _, x := range ok {
		sum += x
	}
	return map[string]float64{"min": ok[0], "avg": sum / float64(len(ok)), "max": ok[len(ok)-1]}
}

func formatLatency(v []float64) string {
	s := latencySummary(v)
	if s == nil {
		return "全部失败"
	}
	return fmt.Sprintf("min/avg/max %.1f/%.1f/%.1f ms", s["min"], s["avg"], s["max"])
}

func displayName(n node) string {
	if n.Name != "" {
		return n.Name
	}
	if n.ID != "" {
		return n.ID
	}
	return n.Host
}

func dovalid(host string, port, bandwidth int, imei string, androidUA string, timeout time.Duration) (string, int64, error) {
	ts := getServerTime(timeout)
	q := url.Values{}
	q.Set("key", "")
	q.Set("flag", "true")
	q.Set("bandwidth", strconv.Itoa(bandwidth))
	q.Set("model", "Android")
	q.Set("imei", imei)
	q.Set("time", strconv.FormatInt(ts, 10))
	q.Set("app", "globalspeed")
	q.Set("token", token(imei, ts, bandwidth))
	q.Set("pkg", appPkg)
	endpoint := fmt.Sprintf("http://%s/speed/dovalid?%s", net.JoinHostPort(host, strconv.Itoa(port)), q.Encode())
	req, _ := http.NewRequest("GET", endpoint, nil)
	if androidUA == "" {
		androidUA = defaultAndroidUA
	}
	req.Header.Set("User-Agent", androidUA)
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := httpClient(timeout, false).Do(req)
	if err != nil {
		return "", ts, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	text := strings.TrimSpace(string(body))
	if strings.HasPrefix(text, "1-") && len(text) > 3 {
		return strings.TrimPrefix(text, "1-"), ts, nil
	}
	return "", ts, fmt.Errorf("HTTP %d: %s", resp.StatusCode, text)
}

func preUploadPost(n node, key string, androidUA string, timeout time.Duration) error {
	endpoint := fmt.Sprintf("http://%s/speed/dovalid?key=%s", net.JoinHostPort(n.Host, strconv.Itoa(n.Port)), url.QueryEscape(key))
	req, _ := http.NewRequest("POST", endpoint, nil)
	if androidUA == "" {
		androidUA = defaultAndroidUA
	}
	req.Header.Set("User-Agent", androidUA)
	resp, err := httpClient(timeout, false).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return nil
}

func downloadProbe(n node, key string, ts int64, timeout time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	address := net.JoinHostPort(n.Host, strconv.Itoa(n.Port))
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", address)
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))
	path := fmt.Sprintf("/speed/File(1G).dl?r=%d&key=%s", ts, url.QueryEscape(key))
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nAccept: */*\r\nConnection: close\r\nUser-Agent: %s\r\nHost: %s\r\n\r\n", path, downloadUA, address)
	if _, err := io.WriteString(conn, req); err != nil {
		return false
	}
	br := bufio.NewReader(conn)
	line, err := br.ReadString('\n')
	return err == nil && strings.Contains(line, " 200 ")
}

func measureDownload(n node, key string, ts int64, o options) speedResult {
	var c counters
	base := context.Background()
	if o.Context != nil {
		base = o.Context
	}
	ctx, cancel := context.WithTimeout(base, o.Duration)
	defer cancel()
	var wg sync.WaitGroup
	for i := 0; i < o.DownloadThreads; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			downloadWorker(ctx, n, key, ts+int64(worker), &c)
		}(i)
	}
	return watch(ctx, &wg, &c, "download", "下载", o.JSON, o.Progress)
}

func downloadWorker(ctx context.Context, n node, key string, ts int64, c *counters) {
	address := net.JoinHostPort(n.Host, strconv.Itoa(n.Port))
	req := fmt.Sprintf("GET /speed/File(1G).dl?r=%d&key=%s HTTP/1.1\r\nAccept: */*\r\nConnection: close\r\nUser-Agent: %s\r\nHost: %s\r\n\r\n", ts, url.QueryEscape(key), downloadUA, address)
	buf := make([]byte, 1024*1024)
	for ctx.Err() == nil {
		conn, err := net.DialTimeout("tcp", address, 3*time.Second)
		if err != nil {
			c.errors.Add(1)
			time.Sleep(120 * time.Millisecond)
			continue
		}
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err = io.WriteString(conn, req); err != nil {
			_ = conn.Close()
			continue
		}
		br := bufio.NewReader(conn)
		status, err := br.ReadString('\n')
		if err != nil || !strings.Contains(status, " 200 ") {
			_ = conn.Close()
			c.errors.Add(1)
			return
		}
		for {
			line, err := br.ReadString('\n')
			if err != nil || line == "\r\n" {
				break
			}
		}
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		for ctx.Err() == nil {
			nread, err := br.Read(buf)
			if nread > 0 {
				c.bytes.Add(int64(nread))
			}
			if err != nil {
				break
			}
		}
		_ = conn.Close()
	}
}

func measureUpload(n node, key string, o options) speedResult {
	var c counters
	base := context.Background()
	if o.Context != nil {
		base = o.Context
	}
	ctx, cancel := context.WithTimeout(base, o.Duration)
	defer cancel()
	var wg sync.WaitGroup
	chunk := make([]byte, 256*1024)
	_, _ = rand.Read(chunk[:4096])
	for i := 0; i < o.UploadThreads; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			uploadWorker(ctx, n, key, worker, chunk, o.UploadContentLen, &c)
		}(i)
	}
	return watch(ctx, &wg, &c, "upload", "上传", o.JSON, o.Progress)
}

func uploadWorker(ctx context.Context, n node, key string, worker int, chunk []byte, contentLen int64, c *counters) {
	address := net.JoinHostPort(n.Host, strconv.Itoa(n.Port))
	for attempt := 1; ctx.Err() == nil; attempt++ {
		conn, err := net.DialTimeout("tcp", address, 5*time.Second)
		if err != nil {
			c.errors.Add(1)
			time.Sleep(120 * time.Millisecond)
			continue
		}
		now := time.Now()
		filename := fmt.Sprintf("SPEED_%s_%d_%d_%03d", now.Format("20060102_150405"), worker, attempt, now.Nanosecond()/1e6)
		prefix := fmt.Sprintf("--%s\r\nContent-Disposition: form-data; name=\"upload\";filename=\"%s\"\r\n\r\n", boundary, filename)
		headers := fmt.Sprintf("POST /speed/doAnalsLoad.do HTTP/1.1\r\nConnection: close\r\nCache-Control: no-cache\r\nCharset: UTF-8\r\nKey: %s\r\nContent-Type: multipart/form-data;boundary=%s\r\nUser-Agent: %s\r\nHost: %s\r\nAccept-Encoding: gzip\r\nContent-Length: %d\r\n\r\n", key, boundary, uploadUA, address, contentLen)
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		if _, err = io.WriteString(conn, headers+prefix); err != nil {
			_ = conn.Close()
			continue
		}
		for ctx.Err() == nil {
			nw, err := conn.Write(chunk)
			if nw > 0 {
				c.bytes.Add(int64(nw))
			}
			if err != nil {
				c.reconnect.Add(1)
				break
			}
		}
		_ = conn.Close()
	}
}

func watch(ctx context.Context, wg *sync.WaitGroup, c *counters, phase string, label string, quiet bool, progress func(string, speedSample)) speedResult {
	start := time.Now()
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	lastT := start
	lastBytes := int64(0)
	peak := 0.0
	for {
		select {
		case <-ticker.C:
			now := time.Now()
			total := c.bytes.Load()
			current := mbps(total-lastBytes, now.Sub(lastT).Seconds())
			if current > peak {
				peak = current
			}
			sample := speedSample{
				T:      now.Sub(start).Seconds(),
				Mbps:   current,
				Bytes:  total,
				Phase:  phase,
				Avg:    mbps(total, now.Sub(start).Seconds()),
				Peak:   peak,
				Errors: c.errors.Load(),
			}
			if progress != nil {
				progress(phase, sample)
			}
			if !quiet {
				fmt.Printf("\r%s实时 %8.2f Mbps  平均 %8.2f Mbps  流量 %.2f MB", label, current, sample.Avg, float64(total)/1024/1024)
			}
			lastT, lastBytes = now, total
		case <-ctx.Done():
			wg.Wait()
			elapsed := time.Since(start).Seconds()
			if !quiet {
				fmt.Println()
			}
			total := c.bytes.Load()
			return speedResult{Bytes: total, Elapsed: elapsed, AvgMbps: mbps(total, elapsed), PeakMbps: peak, Errors: c.errors.Load()}
		case <-done:
			elapsed := time.Since(start).Seconds()
			if !quiet {
				fmt.Println()
			}
			total := c.bytes.Load()
			return speedResult{Bytes: total, Elapsed: elapsed, AvgMbps: mbps(total, elapsed), PeakMbps: peak, Errors: c.errors.Load()}
		}
	}
}

func mbps(bytes int64, seconds float64) float64 {
	if seconds <= 0 {
		return 0
	}
	return float64(bytes) * 8 / seconds / 1_000_000
}
