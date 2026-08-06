package main

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

//go:embed web_assets/app.js web_assets/app.css web_assets/vendor/react.production.min.js web_assets/vendor/react-dom.production.min.js serverlist.json
var webAssets embed.FS

type webJob struct {
	ID       string                   `json:"id"`
	Status   string                   `json:"status"`
	Stage    string                   `json:"stage"`
	Message  string                   `json:"message"`
	Progress int                      `json:"progress"`
	Started  int64                    `json:"started"`
	DoneAt   int64                    `json:"done_at,omitempty"`
	Config   map[string]any           `json:"config"`
	Nodes    []map[string]any         `json:"nodes"`
	Summary  map[string]any           `json:"summary"`
	Samples  map[string][]speedSample `json:"samples"`
	Result   map[string]any           `json:"result"`
	Logs     []map[string]string      `json:"logs"`
	Error    string                   `json:"error,omitempty"`
	cancel   func()
}

var (
	webMu          sync.Mutex
	webJobs        = map[string]*webJob{}
	bundledOnce    sync.Once
	bundledCatalog []node
	bundledErr     error
)

func loadBundledNodes() ([]node, error) {
	bundledOnce.Do(func() {
		raw, err := webAssets.ReadFile("serverlist.json")
		if err != nil {
			bundledErr = err
			return
		}
		var items []map[string]any
		if err := json.Unmarshal(raw, &items); err != nil {
			bundledErr = err
			return
		}
		bundledCatalog = make([]node, 0, len(items))
		for _, item := range items {
			if n, ok := nodeFromMapping(item, "all", false); ok {
				bundledCatalog = append(bundledCatalog, n)
			}
		}
	})
	return bundledCatalog, bundledErr
}

func mergeNodeCatalog(recommended []node) ([]node, error) {
	bundled, err := loadBundledNodes()
	merged := make([]node, 0, len(recommended)+len(bundled))
	byAddress := make(map[string]int, len(recommended)+len(bundled))
	add := func(n node) {
		key := strings.ToLower(net.JoinHostPort(n.Host, fmt.Sprint(n.Port)))
		if index, exists := byAddress[key]; exists {
			current := &merged[index]
			current.Recommended = current.Recommended || n.Recommended
			if current.Source != "recommended" && n.Source == "recommended" {
				current.Source = "recommended"
			}
			if current.ID == "" {
				current.ID = n.ID
			}
			if current.Province == "" {
				current.Province = n.Province
			}
			if current.City == "" {
				current.City = n.City
			}
			if current.Operator == "" {
				current.Operator = n.Operator
			}
			return
		}
		byAddress[key] = len(merged)
		merged = append(merged, n)
	}
	for _, n := range recommended {
		add(n)
	}
	for _, n := range bundled {
		add(n)
	}
	return merged, err
}

const (
	webAppVersion  = "0.9.1"
	webVersionCode = 901
	adminAPIBase   = "https://cnspeedtest.w8.hk"
	adminUserAgent = "CNSpeedTest/0.9.2 (+https://cnspeedtest.w8.hk)"
)

func startWeb(base options) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(fullIndexHTML))
	})
	mux.HandleFunc("/app.js", serveAsset("web_assets/app.js", "application/javascript; charset=utf-8"))
	mux.HandleFunc("/app.css", serveAsset("web_assets/app.css", "text/css; charset=utf-8"))
	mux.HandleFunc("/vendor/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/vendor/")
		if name == "" || strings.Contains(name, "/") {
			http.NotFound(w, r)
			return
		}
		serveAsset("web_assets/vendor/"+name, "application/javascript; charset=utf-8")(w, r)
	})

	mux.HandleFunc("/api/ip-info", func(w http.ResponseWriter, r *http.Request) {
		info, err := getIPInfo(base)
		if err != nil {
			writeJSONStatus(w, http.StatusBadGateway, map[string]string{"error": "\u7528\u6237\u4fe1\u606f\u83b7\u53d6\u5931\u8d25"})
			return
		}
		writeJSON(w, info)
	})
	mux.HandleFunc("/api/nodes", func(w http.ResponseWriter, r *http.Request) {
		recommended, discoverErr := discoverNodes(base)
		nodes, catalogErr := mergeNodeCatalog(recommended)
		if len(nodes) == 0 {
			writeJSONStatus(w, http.StatusBadGateway, map[string]string{"error": "\u8282\u70b9\u5217\u8868\u83b7\u53d6\u5931\u8d25"})
			return
		}
		warnings := make([]string, 0, 2)
		if discoverErr != nil {
			warnings = append(warnings, "recommended node discovery failed; bundled catalog is still available")
		}
		if catalogErr != nil {
			warnings = append(warnings, "bundled node catalog could not be loaded")
		}
		writeJSON(w, map[string]any{
			"nodes":             nodes,
			"recommended_count": len(recommended),
			"total":             len(nodes),
			"warnings":          warnings,
		})
	})
	mux.HandleFunc("/api/start", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Auto            bool    `json:"auto"`
			Host            string  `json:"host"`
			Port            int     `json:"port"`
			ManualName      string  `json:"manualName"`
			Duration        int     `json:"duration"`
			SampleInterval  float64 `json:"sampleInterval"`
			DownloadThreads int     `json:"downloadThreads"`
			UploadThreads   int     `json:"uploadThreads"`
			RunDownload     bool    `json:"runDownload"`
			RunUpload       bool    `json:"runUpload"`
			ForceDownload   bool    `json:"forceDownload"`
			DownloadProbe   bool    `json:"downloadProbe"`
			Bandwidth       int     `json:"bandwidth"`
			ProbeOnly       bool    `json:"probeOnly"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)

		o := base
		o.Web = false
		o.JSON = true
		o.Auto = req.Auto
		o.ManualName = req.ManualName
		if req.Host != "" {
			o.Host = req.Host
		}
		if req.Port > 0 {
			o.Port = req.Port
		}
		if req.Duration > 0 {
			o.Duration = time.Duration(req.Duration) * time.Second
		}
		if req.DownloadThreads > 0 {
			o.DownloadThreads = req.DownloadThreads
		}
		if req.UploadThreads > 0 {
			o.UploadThreads = req.UploadThreads
		}
		if req.Bandwidth > 0 {
			o.Bandwidth = req.Bandwidth
		}
		o.RunDownload = req.RunDownload
		o.RunUpload = req.RunUpload
		o.ForceDownload = req.ForceDownload
		o.NoDownloadProbe = !req.DownloadProbe
		if !o.RunDownload && !o.RunUpload {
			o.RunDownload, o.RunUpload = true, true
		}
		ctx, cancel := contextWithCancel()
		o.Context = ctx
		job := &webJob{
			ID:       randomTSIMEI(),
			Status:   "running",
			Stage:    "\u542f\u52a8",
			Progress: 3,
			Started:  time.Now().Unix(),
			Config: map[string]any{
				"run_download": o.RunDownload,
				"run_upload":   o.RunUpload,
				"auto":         o.Auto,
				"machine_id":   o.MachineID,
				"imei":         o.IMEI,
				"android_ua":   o.AndroidUA,
			},
			Summary: map[string]any{},
			Samples: map[string][]speedSample{"download": {}, "upload": {}},
			Result:  map[string]any{},
			Logs:    []map[string]string{},
			cancel:  cancel,
		}
		o.Progress = func(phase string, sample speedSample) {
			webMu.Lock()
			defer webMu.Unlock()
			job.Samples[phase] = append(job.Samples[phase], sample)
			if len(job.Samples[phase]) > 300 {
				job.Samples[phase] = job.Samples[phase][len(job.Samples[phase])-300:]
			}
			job.Summary["live_phase"] = phase
			job.Summary["live_mbps"] = sample.Mbps
			job.Summary[phase+"_mbps"] = sample.Avg
			job.Summary[phase+"_peak_mbps"] = sample.Peak
			job.Summary[phase+"_bytes"] = sample.Bytes
		}

		webMu.Lock()
		webJobs[job.ID] = job
		webMu.Unlock()

		go runWebJob(job, o)
		writeJSON(w, map[string]string{"job_id": job.ID})
	})
	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("id")
		webMu.Lock()
		job := webJobs[id]
		webMu.Unlock()
		if job == nil {
			http.Error(w, "job not found", http.StatusNotFound)
			return
		}
		webMu.Lock()
		copyBytes, _ := json.Marshal(job)
		webMu.Unlock()
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(copyBytes)
	})
	mux.HandleFunc("/api/app-info", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"platform":     "openwrt",
			"version":      webAppVersion,
			"version_code": webVersionCode,
			"machine_id":   base.MachineID,
			"can_shutdown": false,
		})
	})
	mux.HandleFunc("/api/client-check", func(w http.ResponseWriter, r *http.Request) {
		data, err := remoteClientCheck(base, r.URL.Query())
		if err != nil {
			writeJSONStatus(w, http.StatusBadGateway, map[string]string{"error": "check failed"})
			return
		}
		writeJSON(w, data)
	})
	mux.HandleFunc("/api/network-type", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"network_type": lookupNetworkType(base, r.URL.Query().Get("ip"))})
	})
	mux.HandleFunc("/api/cancel", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("id")
		if id == "" {
			var req struct {
				ID string `json:"id"`
			}
			_ = json.NewDecoder(r.Body).Decode(&req)
			id = req.ID
		}

		webMu.Lock()
		job := webJobs[id]
		if job != nil && job.cancel != nil && job.Status == "running" {
			job.Status = "cancelling"
			job.Stage = "\u505c\u6b62\u4e2d"
			job.Message = "\u6b63\u5728\u7ec8\u6b62\u6d4b\u901f"
			job.cancel()
		}
		webMu.Unlock()
		writeJSON(w, map[string]bool{"ok": job != nil})
	})
	mux.HandleFunc("/api/report", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			writeJSONStatus(w, http.StatusBadRequest, map[string]string{"error": "bad request"})
			return
		}
		data, err := submitRemoteReport(base, payload)
		if err != nil {
			writeJSONStatus(w, http.StatusBadGateway, map[string]string{"error": "report failed"})
			return
		}
		writeJSON(w, data)
	})
	mux.HandleFunc("/api/shutdown", func(w http.ResponseWriter, r *http.Request) {
		writeJSONStatus(w, http.StatusForbidden, map[string]string{"error": "managed by procd"})
	})

	fmt.Printf("OpenWrt Speed Web running at http://%s\n", base.Listen)
	return http.ListenAndServe(base.Listen, mux)
}

func runWebJob(job *webJob, o options) {
	setJob(job, "TCP Ping", "\u6b63\u5728\u9009\u62e9\u8282\u70b9", 12)
	choice, err := chooseNode(o)
	if err != nil {
		failJob(job, err)
		return
	}

	webMu.Lock()
	latency := latencySummary(choice.Latencies)
	job.Result["node"] = choice.Node
	job.Nodes = []map[string]any{{
		"index":          choice.Index,
		"name":           displayName(choice.Node),
		"host":           choice.Node.Host,
		"port":           choice.Node.Port,
		"latency_avg_ms": latencyValue(latency, "avg"),
		"reachable":      latency != nil,
		"selected":       true,
	}}
	if latency != nil {
		job.Summary["latency_avg_ms"] = latency["avg"]
		job.Summary["latency_min_ms"] = latency["min"]
		job.Summary["latency_max_ms"] = latency["max"]
	}
	webMu.Unlock()

	setJob(job, "dovalid", "\u6b63\u5728\u83b7\u53d6\u6388\u6743", 54)
	key, ts, err := dovalid(choice.Node.Host, choice.Node.Port, o.Bandwidth, o.IMEI, o.AndroidUA, 5*time.Second)
	if err != nil {
		failJob(job, err)
		return
	}
	webMu.Lock()
	job.Summary["dovalid_mode"] = "globalspeed-4.4-native"
	webMu.Unlock()

	if o.RunDownload {
		setJob(job, "\u4e0b\u8f7d", "\u5f00\u59cb\u4e0b\u8f7d\u6d4b\u901f", 62)
		if !o.NoDownloadProbe && !downloadProbe(choice.Node, key, ts, 5*time.Second) && !o.ForceDownload {
			failJob(job, fmt.Errorf("download probe failed"))
			return
		}
		res := measureDownload(choice.Node, key, ts, o)
		webMu.Lock()
		job.Result["download"] = res
		job.Summary["download_mbps"] = res.AvgMbps
		job.Summary["download_peak_mbps"] = res.PeakMbps
		job.Summary["download_bytes"] = res.Bytes
		webMu.Unlock()
	}
	if o.RunUpload {
		setJob(job, "\u4e0a\u4f20", "\u5f00\u59cb\u4e0a\u4f20\u6d4b\u901f", 84)
		_ = preUploadPost(choice.Node, key, o.AndroidUA, 5*time.Second)
		res := measureUpload(choice.Node, key, o)
		webMu.Lock()
		job.Result["upload"] = res
		job.Summary["upload_mbps"] = res.AvgMbps
		job.Summary["upload_peak_mbps"] = res.PeakMbps
		job.Summary["upload_bytes"] = res.Bytes
		webMu.Unlock()
	}

	webMu.Lock()
	if job.Status == "cancelling" {
		job.Status = "cancelled"
		job.Stage = "\u5df2\u505c\u6b62"
		job.Message = "\u6d4b\u901f\u5df2\u7ec8\u6b62"
		job.Summary["live_phase"] = ""
	} else {
		job.Status = "done"
		job.Stage = "\u5b8c\u6210"
		job.Message = "\u7ed3\u679c\u5df2\u751f\u6210"
		job.Progress = 100
		job.Summary["live_phase"] = ""
	}
	job.DoneAt = time.Now().Unix()
	webMu.Unlock()
}

func setJob(job *webJob, stage, msg string, progress int) {
	webMu.Lock()
	defer webMu.Unlock()
	job.Stage = stage
	job.Message = msg
	if progress > 0 {
		job.Progress = progress
	}
	job.Logs = append(job.Logs, map[string]string{"time": time.Now().Format("15:04:05"), "message": strings.TrimSpace(stage + " " + msg)})
	if len(job.Logs) > 200 {
		job.Logs = job.Logs[len(job.Logs)-200:]
	}
}

func failJob(job *webJob, err error) {
	webMu.Lock()
	defer webMu.Unlock()
	job.Status = "error"
	job.Stage = "\u5931\u8d25"
	job.Progress = 100
	job.Error = err.Error()
	job.Message = err.Error()
	job.Summary["live_phase"] = ""
	job.DoneAt = time.Now().Unix()
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func contextWithCancel() (context.Context, func()) {
	return context.WithCancel(context.Background())
}

func serveAsset(name string, contentType string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		data, err := fs.ReadFile(webAssets, name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", contentType)
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(data)
	}
}

func writeJSONStatus(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func latencyValue(m map[string]float64, key string) any {
	if m == nil {
		return nil
	}
	return m[key]
}

func remoteClientCheck(base options, params url.Values) (map[string]any, error) {
	q := url.Values{}
	q.Set("platform", firstQuery(params, "platform", "openwrt"))
	q.Set("version", firstQuery(params, "version", webAppVersion))
	q.Set("version_code", firstQuery(params, "version_code", fmt.Sprint(webVersionCode)))
	q.Set("channel", firstQuery(params, "channel", "stable"))
	q.Set("machine_id", firstQuery(params, "machine_id", base.MachineID))
	req, err := http.NewRequest("GET", adminAPIBase+"/api/client/check?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", adminUserAgent)
	req.Header.Set("Accept", "application/json")
	resp, err := directHTTPClient(3*time.Second, base.InsecureDiscovery).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("check status %d", resp.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

func lookupNetworkType(base options, publicIP string) string {
	publicIP = strings.TrimSpace(publicIP)
	if publicIP == "" {
		return "未知"
	}
	u := "https://cz88.net/api/cz88/ip/base?ip=" + url.QueryEscape(publicIP)
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return "未知"
	}
	req.Header.Set("User-Agent", adminUserAgent)
	req.Header.Set("Accept", "application/json")
	resp, err := directHTTPClient(3*time.Second, base.InsecureDiscovery).Do(req)
	if err != nil {
		return "未知"
	}
	defer resp.Body.Close()
	var payload struct {
		Data struct {
			NetworkType string `json:"netWorkType"`
		} `json:"data"`
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "未知"
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "未知"
	}
	if strings.TrimSpace(payload.Data.NetworkType) == "" {
		return "未知"
	}
	return payload.Data.NetworkType
}

func submitRemoteReport(base options, payload map[string]any) (map[string]any, error) {
	if payload == nil {
		payload = map[string]any{}
	}
	if _, ok := payload["machine_id"]; !ok {
		payload["machine_id"] = base.MachineID
	}
	if _, ok := payload["app_version"]; !ok {
		payload["app_version"] = webAppVersion
	}
	if _, ok := payload["platform"]; !ok {
		payload["platform"] = "openwrt"
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest("POST", adminAPIBase+"/api/reports", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", adminUserAgent)
	req.Header.Set("Accept", "application/json")
	resp, err := directHTTPClient(3*time.Second, base.InsecureDiscovery).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("report status %d", resp.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

func firstQuery(values url.Values, key, fallback string) string {
	value := strings.TrimSpace(values.Get(key))
	if value == "" {
		return fallback
	}
	return value
}

func directHTTPClient(timeout time.Duration, insecure bool) *http.Client {
	client := httpClient(timeout, insecure)
	if transport, ok := client.Transport.(*http.Transport); ok {
		transport.Proxy = nil
	}
	return client
}

func getIPInfo(base options) (map[string]any, error) {
	req, _ := http.NewRequest("GET", "https://dlcv2.cnspeedtest.cn:8443/dataServer/getIpLocSP.php", nil)
	req.Header.Set("User-Agent", base.AndroidUA)
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := httpClient(5*time.Second, base.InsecureDiscovery).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimSpace(string(raw)), "|")
	publicIP := ""
	if len(parts) > 0 {
		publicIP = parts[0]
	}
	province, city, carrier := "", "", ""
	if len(parts) > 1 {
		var loc []string
		_ = json.Unmarshal([]byte(parts[1]), &loc)
		if len(loc) > 1 {
			province = loc[1]
		}
		if len(loc) > 2 {
			city = loc[2]
		}
		if len(loc) > 4 {
			carrier = loc[4]
		}
	}
	if len(parts) > 3 && parts[3] != "" {
		carrier = parts[3]
	}
	return map[string]any{
		"ip":       publicIP,
		"province": province,
		"city":     city,
		"carrier":  carrier,
		"location": strings.TrimSpace(province + " " + city),
	}, nil
}

const fullIndexHTML = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CNSpeedTest</title>
  <link rel="stylesheet" href="/app.css">
</head>
<body>
  <div id="root"></div>
  <script src="/vendor/react.production.min.js"></script>
  <script src="/vendor/react-dom.production.min.js"></script>
  <script src="/app.js"></script>
</body>
</html>`
