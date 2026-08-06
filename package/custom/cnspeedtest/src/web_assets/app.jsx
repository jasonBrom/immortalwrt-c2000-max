const { useEffect, useMemo, useRef, useState } = React;

function cn(...classes) {
  return classes.filter(Boolean).join(" ");
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function formatSpeed(value) {
  const number = Number(value) || 0;
  return number >= 100 ? number.toFixed(0) : number.toFixed(2);
}

function formatDataFromBytes(bytes, locale = "zh") {
  const mb = (Number(bytes) || 0) / 1024 / 1024;
  if (mb >= 1024) {
    const gb = mb / 1024;
    return gb >= 10 ? `${gb.toFixed(1)} GB` : `${gb.toFixed(2)} GB`;
  }
  if (mb >= 100) return `${mb.toFixed(0)} MB`;
  if (mb >= 10) return `${mb.toFixed(1)} MB`;
  return `${mb.toFixed(2)} MB`;
}

function formatTickLabel(value) {
  if (value >= 1000) {
    const g = value / 1000;
    return Number.isInteger(g) ? `${g}G` : `${g.toFixed(1)}G`;
  }
  return `${value}`;
}

function polarToCartesian(cx, cy, r, angleDeg) {
  const angleRad = ((angleDeg - 90) * Math.PI) / 180;
  return {
    x: cx + r * Math.cos(angleRad),
    y: cy + r * Math.sin(angleRad),
  };
}

function describeArc(cx, cy, r, startAngle, endAngle) {
  const start = polarToCartesian(cx, cy, r, endAngle);
  const end = polarToCartesian(cx, cy, r, startAngle);
  const largeArcFlag = endAngle - startAngle <= 180 ? "0" : "1";
  return ["M", start.x, start.y, "A", r, r, 0, largeArcFlag, 0, end.x, end.y].join(" ");
}

const GAUGE_MAX_MBPS = 3000;
const GAUGE_BREAK_MBPS = 1000;
const GAUGE_BREAK_PERCENT = 0.8;
const TICK_LABEL_VALUES = [0, 200, 400, 600, 800, 1000, 2000, 3000];
const TICK_VALUES = [
  ...Array.from({ length: 21 }, (_, index) => index * 50),
  1250,
  1500,
  1750,
  2000,
  2250,
  2500,
  2750,
  3000,
];
const APP_VERSION = "0.9.2";
const APP_VERSION_CODE = 902;
const DEFAULT_APP_INFO = { platform: "desktop", version: APP_VERSION, version_code: APP_VERSION_CODE, machine_id: "" };

async function fetchJSONWithTimeout(url, options = {}, timeoutMs = 3000) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || "request failed");
    return data;
  } finally {
    window.clearTimeout(timer);
  }
}

function getThemeLabel(mode, t) {
  if (mode === "dark") return t.darkMode;
  if (mode === "light") return t.lightMode;
  return t.systemMode;
}

function initialThemeMode() {
  const requested = new URLSearchParams(window.location.search).get("theme");
  if (["system", "light", "dark"].includes(requested)) return requested;
  const saved = window.localStorage.getItem("cnspeed_theme");
  return ["system", "light", "dark"].includes(saved) ? saved : "system";
}

const LOCALES = {
  zh: {
    appTitle: "网速测试",
    appSubtitle: "BY：Inst",
    about: "关于",
    author: "作者",
    version: "版本",
    platform: "平台",
    machineId: "机器 ID",
    checkUpdate: "检查更新",
    checkingUpdate: "检查中...",
    updateLatest: "已是最新版本",
    updateAvailable: "发现新版本",
    updateBlocked: "当前版本已禁用",
    updateStatus: "更新状态",
    noVersionInfo: "暂无版本信息",
    announcementPopupTitle: "公告",
    announcements: "公告",
    theme: "主题",
    systemMode: "跟随系统",
    lightMode: "浅色",
    darkMode: "深色",
    language: "语言",
    chinese: "中文",
    english: "English",
    ping: "Ping",
    jitter: "抖动",
    totalData: "总流量",
    quality: "质量",
    roundTripLatency: "TCP 平均延迟",
    latencyVariation: "延迟波动",
    totalTrafficHelper: "下载 + 上传",
    overallEvaluation: "综合评估",
    routerSpeedNotice: "本页面测试的是路由器到外网的速度；结果可能受分流、QoS、代理、硬件加速及其他路由器配置影响而波动。",
    userInfo: "用户信息",
    userIp: "公网 IP",
    region: "地域",
    carrier: "运营商",
    networkType: "网络类型",
    unknown: "未知",
    loading: "获取中",
    unavailable: "获取失败",
    hideSensitive: "隐藏敏感信息",
    showSensitive: "显示敏感信息",
    exitApp: "退出",
    exitConfirm: "确定要退出程序吗？",
    exitNotice: "程序正在退出",
    nodeSettings: "节点设置",
    nodeMode: "节点模式",
    autoNode: "自动选择",
    manualNode: "手动选择",
    loadNodes: "加载节点",
    loadingNodes: "加载中...",
    searchNodes: "搜索节点、地区、运营商或 IP",
    nodeCount: "共 {count} 个节点",
    nodeSearchCount: "匹配 {shown} / {total} 个节点",
    recommendedNode: "推荐",
    complete: "完成",
    noNodes: "暂无节点",
    selectNodeFirst: "请先选择一个节点",
    currentPhase: "当前阶段",
    readyToStart: "准备开始",
    discovering: "选择节点",
    downloading: "下载测试中",
    uploading: "上传测试中",
    resultReady: "结果已生成",
    failed: "测试失败",
    download: "下载",
    upload: "上传",
    ready: "就绪",
    testing: "测试中...",
    stopping: "停止中...",
    stopTest: "停止",
    cancelled: "已终止",
    restartTest: "重新测试",
    startTest: "开始测试",
    downloadResult: "下载结果",
    uploadResult: "上传结果",
    max: "峰值",
    avg: "平均",
    used: "用量",
    traffic: "流量",
    server: "节点",
    downloadCurve: "下载曲线",
    uploadCurve: "上传曲线",
    downloadCurveDesc: "下载 15 秒实时速度变化",
    uploadCurveDesc: "上传 15 秒实时速度变化",
    live: "实时",
    idle: "空闲",
    noDataYet: "暂无数据",
    speedGauge: "网速测试仪表盘",
    errorTitle: "出现问题",
    errorHint: "请检查服务器连接、节点状态，或查看运行目录下的错误日志。",
    notTested: "未测试",
    excellent: "优秀",
    good: "良好",
    fair: "一般",
    error: "错误",
  },
  en: {
    appTitle: "NetSpeed Test",
    appSubtitle: "BY：Inst",
    about: "About",
    author: "Author",
    version: "Version",
    platform: "Platform",
    machineId: "Machine ID",
    checkUpdate: "Check update",
    checkingUpdate: "Checking...",
    updateLatest: "You're up to date",
    updateAvailable: "Update available",
    updateBlocked: "This version is blocked",
    updateStatus: "Update status",
    noVersionInfo: "No version info",
    announcementPopupTitle: "Notice",
    announcements: "Announcements",
    theme: "Theme",
    systemMode: "System",
    lightMode: "Light",
    darkMode: "Dark",
    language: "Language",
    chinese: "中文",
    english: "English",
    ping: "Ping",
    jitter: "Jitter",
    totalData: "Total Data",
    quality: "Quality",
    roundTripLatency: "TCP average latency",
    latencyVariation: "Latency variation",
    totalTrafficHelper: "Download + upload",
    overallEvaluation: "Overall evaluation",
    routerSpeedNotice: "This page measures the router-to-Internet path. Results may vary with routing policies, QoS, proxies, hardware offload, and other router settings.",
    userInfo: "User Info",
    userIp: "Public IP",
    region: "Region",
    carrier: "Carrier",
    networkType: "Network",
    unknown: "Unknown",
    loading: "Loading",
    unavailable: "Unavailable",
    hideSensitive: "Hide sensitive data",
    showSensitive: "Show sensitive data",
    exitApp: "Exit",
    exitConfirm: "Exit the application?",
    exitNotice: "Application is exiting",
    nodeSettings: "Node Settings",
    nodeMode: "Node mode",
    autoNode: "Auto",
    manualNode: "Manual",
    loadNodes: "Load nodes",
    loadingNodes: "Loading...",
    searchNodes: "Search node, region, carrier, or IP",
    nodeCount: "{count} nodes",
    nodeSearchCount: "{shown} / {total} matched",
    recommendedNode: "Recommended",
    complete: "Done",
    noNodes: "No nodes",
    selectNodeFirst: "Please select a node first",
    currentPhase: "Current phase",
    readyToStart: "Ready to start",
    discovering: "Choosing server",
    downloading: "Downloading",
    uploading: "Uploading",
    resultReady: "Result ready",
    failed: "Test failed",
    download: "Download",
    upload: "Upload",
    ready: "Ready",
    testing: "Testing...",
    stopping: "Stopping...",
    stopTest: "Stop",
    cancelled: "Cancelled",
    restartTest: "Restart test",
    startTest: "Start test",
    downloadResult: "Download Result",
    uploadResult: "Upload Result",
    max: "Peak",
    avg: "Avg",
    used: "Used",
    traffic: "Traffic",
    server: "Server",
    downloadCurve: "Download Curve",
    uploadCurve: "Upload Curve",
    downloadCurveDesc: "Live speed during 15s download",
    uploadCurveDesc: "Live speed during 15s upload",
    live: "Live",
    idle: "Idle",
    noDataYet: "No data yet",
    speedGauge: "Speed test gauge",
    errorTitle: "Something went wrong",
    errorHint: "Check the server connection, node status, or the error log in the app folder.",
    notTested: "Not tested",
    excellent: "Excellent",
    good: "Good",
    fair: "Fair",
    error: "Error",
  },
};

function speedToPercent(speed, max = GAUGE_MAX_MBPS) {
  const value = clamp(Number(speed) || 0, 0, max);
  if (value <= GAUGE_BREAK_MBPS) {
    return (value / GAUGE_BREAK_MBPS) * GAUGE_BREAK_PERCENT;
  }
  return GAUGE_BREAK_PERCENT + ((value - GAUGE_BREAK_MBPS) / (max - GAUGE_BREAK_MBPS)) * (1 - GAUGE_BREAK_PERCENT);
}

function speedToAngle(speed, max = GAUGE_MAX_MBPS) {
  return -115 + speedToPercent(speed, max) * 230;
}

function qualityKey(downloadMax, uploadMax, ping, jitter) {
  if (downloadMax <= 0 && uploadMax <= 0) return "notTested";
  if (downloadMax >= 1500 && uploadMax >= 300 && ping <= 15 && jitter <= 5) return "excellent";
  if (downloadMax >= 500 && uploadMax >= 80 && ping <= 45) return "good";
  return "fair";
}

function phaseFromJob(job) {
  const summaryPhase = job?.summary?.live_phase;
  if (summaryPhase === "download" || summaryPhase === "upload") return summaryPhase;
  if (job?.status === "cancelled" || job?.status === "cancelling") return "cancelled";
  const stage = String(job?.stage || "");
  if (stage.includes("终止") || stage.includes("停止")) return "cancelled";
  if (stage.includes("上传")) return "upload";
  if (stage.includes("下载")) return "download";
  if (stage.includes("失败")) return "error";
  if (stage.includes("完成")) return "complete";
  if (stage.includes("节点") || stage.includes("TCP") || stage.includes("Ping") || stage.includes("dovalid")) return "discover";
  return "idle";
}

function averageFromSeries(series) {
  if (!series.length) return 0;
  return series.reduce((sum, item) => sum + (Number(item.mbps) || 0), 0) / series.length;
}

function peakFromSeries(series) {
  if (!series.length) return 0;
  return Math.max(...series.map((item) => Number(item.mbps) || 0));
}

function nodeNameFromJob(job) {
  const node = job?.result?.node;
  if (node?.name && node.name !== "manual") return node.name;
  const selected = (job?.nodes || []).find((item) => item.selected);
  if (selected?.name && selected.name !== "manual") return selected.name;
  return "Auto";
}

function displayNodeName(job, nodeMode, selectedNode, manualFallback) {
  if (nodeMode === "manual") {
    return selectedNode?.name || manualFallback;
  }
  return nodeNameFromJob(job);
}

function carrierFromText(text, fallback = "") {
  const value = String(text || "");
  const fallbackValue = String(fallback || "");
  const carriers = [
    "中国移动",
    "中国联通",
    "中国电信",
    "中国广电",
    "移动",
    "联通",
    "电信",
    "广电",
    "China Mobile",
    "China Unicom",
    "China Telecom",
  ];
  return carriers.find((carrier) => value.includes(carrier) || fallbackValue.includes(carrier)) || fallbackValue || "";
}

function maskWithCarrier(value, fallbackCarrier = "") {
  const text = String(value || "");
  const carrier = carrierFromText(text, fallbackCarrier);
  if (!carrier) return text ? "**" : "--";
  return `**${carrier}`;
}

function maskText(value, minStars = 4) {
  const text = String(value || "");
  if (!text) return "--";
  return "*".repeat(Math.max(minStars, Math.min(8, text.length)));
}

function IconSpeed({ className = "" }) {
  return (
    <svg viewBox="0 0 32 32" className={className} fill="none" aria-hidden="true">
      <path d="M5.5 21.5a10.5 10.5 0 0 1 21 0" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" opacity="0.35" />
      <path d="M5.5 21.5A10.5 10.5 0 0 1 21.8 12" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" />
      <circle cx="16" cy="21.2" r="1.8" fill="currentColor" />
    </svg>
  );
}

function IconServer({ className = "" }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden="true">
      <rect x="4" y="5" width="16" height="5" rx="1.6" stroke="currentColor" strokeWidth="1.7" />
      <rect x="4" y="14" width="16" height="5" rx="1.6" stroke="currentColor" strokeWidth="1.7" />
      <path d="M7.2 7.5h.01M7.2 16.5h.01M11 7.5h5.8M11 16.5h5.8" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  );
}

function IconMapPin({ className = "" }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden="true">
      <path d="M12 21s6-5.4 6-11a6 6 0 1 0-12 0c0 5.6 6 11 6 11Z" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
      <circle cx="12" cy="10" r="2.2" stroke="currentColor" strokeWidth="1.8" />
    </svg>
  );
}

function IconEye({ hidden = false, className = "" }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden="true">
      <path d="M3.8 12s2.9-5.2 8.2-5.2S20.2 12 20.2 12s-2.9 5.2-8.2 5.2S3.8 12 3.8 12Z" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
      <circle cx="12" cy="12" r="2.4" stroke="currentColor" strokeWidth="1.8" />
      {hidden ? <path d="M4.5 19.5 19.5 4.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" /> : null}
    </svg>
  );
}

function IconLanguage({ className = "" }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden="true">
      <path d="M4 5.5h9M8.5 3.8v1.7M11.7 5.5c-.9 2.8-2.6 5-5.6 6.6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M5.3 7.9c1.2 2 2.8 3.4 5.2 4.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M14.2 19.5l3-8 3 8M15.3 16.6h3.8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function IconSun({ className = "" }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden="true">
      <circle cx="12" cy="12" r="4" stroke="currentColor" strokeWidth="1.8" />
      <path d="M12 2.8v2.1M12 19.1v2.1M21.2 12h-2.1M4.9 12H2.8M18.5 5.5 17 7M7 17l-1.5 1.5M18.5 18.5 17 17M7 7 5.5 5.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  );
}

function IconMoon({ className = "" }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden="true">
      <path d="M20.2 14.4A7.6 7.6 0 0 1 9.6 3.8a8.3 8.3 0 1 0 10.6 10.6Z" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function IconMonitor({ className = "" }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" aria-hidden="true">
      <rect x="3.5" y="4.5" width="17" height="12" rx="2" stroke="currentColor" strokeWidth="1.8" />
      <path d="M9 20h6M12 16.5V20" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  );
}

function Surface({ className = "", children }) {
  return (
    <div className={cn("rounded-[28px] border border-slate-200/80 bg-white shadow-sm", className)}>
      {children}
    </div>
  );
}

function FilledButton({ className = "", children, ...props }) {
  return (
    <button
      className={cn(
        "inline-flex h-12 items-center justify-center rounded-full bg-blue-600 px-6 text-sm font-semibold text-white shadow-sm transition hover:bg-blue-700 active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-60",
        className
      )}
      {...props}
    >
      {children}
    </button>
  );
}

function MetricCard({ label, value, unit, helper }) {
  return (
    <Surface className="p-5">
      <div className="text-xs font-semibold uppercase tracking-[0.12em] text-slate-500">{label}</div>
      <div className="mt-3 flex items-end gap-2">
        <div className="text-3xl font-semibold tracking-tight text-slate-950">{value}</div>
        {unit ? <div className="pb-1 text-sm font-medium text-slate-500">{unit}</div> : null}
      </div>
      <div className="mt-3 text-xs text-slate-400">{helper}</div>
    </Surface>
  );
}

function LanguageSwitch({ locale, setLocale, t }) {
  const items = [
    { key: "zh", label: t.chinese },
    { key: "en", label: t.english },
  ];

  return (
    <div className="flex items-center gap-2 rounded-full bg-slate-100 p-1" aria-label={t.language}>
      <div className="hidden h-10 w-10 place-items-center rounded-full text-slate-500 sm:grid">
        <IconLanguage className="h-5 w-5" />
      </div>
      {items.map((item) => (
        <button
          key={item.key}
          type="button"
          onClick={() => setLocale(item.key)}
          className={cn(
            "h-10 rounded-full px-4 text-sm font-bold transition",
            locale === item.key ? "bg-white text-blue-700 shadow-sm" : "text-slate-500 hover:text-slate-800"
          )}
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}

function ThemeButton({ mode, onToggle, t }) {
  const Icon = mode === "dark" ? IconMoon : mode === "light" ? IconSun : IconMonitor;
  return (
    <button
      type="button"
      onClick={onToggle}
      className="cnspeed-theme-button"
      title={`${t.theme}: ${getThemeLabel(mode, t)}`}
      aria-label={`${t.theme}: ${getThemeLabel(mode, t)}`}
    >
      <Icon className="h-5 w-5" />
    </button>
  );
}

function AboutModal({ open, onClose, t, appInfo, updateInfo, updateChecking, onCheckUpdate }) {
  if (!open) return null;
  const latest = updateInfo?.latest;
  const blocked = Boolean(updateInfo?.blocked);
  const hasUpdate = Boolean(updateInfo?.has_update || (latest?.version && latest.version !== (appInfo.version || APP_VERSION)));
  const statusText = blocked ? t.updateBlocked : hasUpdate ? `${t.updateAvailable}: ${latest.version}` : latest?.version ? t.updateLatest : updateInfo ? t.noVersionInfo : "";
  const announcements = Array.isArray(updateInfo?.announcements) ? updateInfo.announcements : [];

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-slate-950/40 px-4 py-5 backdrop-blur-sm sm:items-center">
      <div className="cnspeed-about-modal w-full max-w-lg rounded-[28px] bg-white p-5 shadow-2xl sm:p-6" role="dialog" aria-modal="true" aria-label={t.about}>
        <div className="cnspeed-about-head flex items-start justify-between gap-4">
          <div>
            <div className="cnspeed-about-title">{t.about}</div>
            <div className="cnspeed-about-subtitle">CNSpeedTest</div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="cnspeed-about-close"
            aria-label={t.complete}
            title={t.complete}
          >
            ×
          </button>
        </div>

        <div className="cnspeed-about-info">
          <div className="cnspeed-about-row">
            <span>{t.author}</span>
            <span className="font-semibold text-slate-950">inst</span>
          </div>
          <div className="cnspeed-about-row">
            <span>{t.version}</span>
            <span className="cnspeed-about-value">{appInfo.version || APP_VERSION}</span>
          </div>
          <div className="cnspeed-about-row">
            <span>{t.platform}</span>
            <span className="cnspeed-about-value">{appInfo.platform || "desktop"}</span>
          </div>
          {appInfo.machine_id ? (
            <div className="cnspeed-about-row cnspeed-about-row-machine">
              <span>{t.machineId}</span>
              <span className="cnspeed-machine-id">{appInfo.machine_id}</span>
            </div>
          ) : null}
        </div>

        <div className="cnspeed-update-card">
          <div className="cnspeed-update-line">
            <div className="cnspeed-section-label">{t.updateStatus}</div>
            <div className="cnspeed-update-status">{statusText || t.noVersionInfo}</div>
          </div>
          <button
            type="button"
            onClick={onCheckUpdate}
            disabled={updateChecking}
            className="cnspeed-check-button"
          >
            {updateChecking ? t.checkingUpdate : t.checkUpdate}
          </button>
        </div>

        {announcements.length > 0 ? (
          <div className="cnspeed-about-section">
            <div className="cnspeed-section-label">{t.announcements}</div>
            <div className="cnspeed-about-announcements">
              {announcements.slice(0, 3).map((item) => (
                <div key={item.id || item.title} className="cnspeed-about-announcement">
                  <div className="cnspeed-about-announcement-title">{item.title}</div>
                  {item.body ? <div className="cnspeed-about-announcement-body">{item.body}</div> : null}
                </div>
              ))}
            </div>
          </div>
        ) : null}

        <FilledButton type="button" onClick={onClose} className="cnspeed-about-done w-full">
          {t.complete}
        </FilledButton>
      </div>
    </div>
  );
}

function AnnouncementModal({ open, onClose, t, updateInfo, appInfo }) {
  if (!open || !updateInfo) return null;
  const latest = updateInfo.latest;
  const blocked = Boolean(updateInfo.blocked);
  const hasUpdate = Boolean(updateInfo.has_update || (latest?.version && latest.version !== (appInfo.version || APP_VERSION)));
  const announcements = Array.isArray(updateInfo.announcements) ? updateInfo.announcements : [];
  if (!blocked && !hasUpdate && announcements.length === 0) return null;
  const statusText = blocked ? t.updateBlocked : hasUpdate ? `${t.updateAvailable}: ${latest.version}` : "";

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-slate-950/40 px-4 py-5 backdrop-blur-sm sm:items-center">
      <div className="w-full max-w-lg rounded-[28px] bg-white p-5 shadow-2xl sm:p-6" role="dialog" aria-modal="true" aria-label={t.announcementPopupTitle}>
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-lg font-bold text-slate-950">{t.announcementPopupTitle}</div>
            {statusText ? <div className="mt-1 text-sm font-semibold text-blue-700">{statusText}</div> : null}
          </div>
          <button
            type="button"
            onClick={onClose}
            className="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-slate-100 text-xl font-semibold leading-none text-slate-500 transition hover:bg-slate-200 hover:text-slate-800"
            aria-label={t.complete}
            title={t.complete}
          >
            ×
          </button>
        </div>

        <div className="mt-5 space-y-3">
          {announcements.length > 0 ? (
            announcements.slice(0, 5).map((item) => (
              <div key={item.id || item.title} className="rounded-2xl bg-slate-50 px-4 py-3 text-sm">
                <div className="font-semibold text-slate-950">{item.title}</div>
                {item.body ? <div className="mt-1 whitespace-pre-wrap text-slate-500">{item.body}</div> : null}
                {item.download_url ? <div className="mt-2 truncate text-xs font-semibold text-blue-700">{item.download_url}</div> : null}
              </div>
            ))
          ) : (
            <div className="rounded-2xl bg-slate-50 px-4 py-3 text-sm font-semibold text-slate-700">{statusText}</div>
          )}
        </div>

        <FilledButton type="button" onClick={onClose} className="mt-5 w-full">
          {t.complete}
        </FilledButton>
      </div>
    </div>
  );
}

function Gauge({ speed, phase, t }) {
  const centerX = 220;
  const centerY = 205;
  const radius = 145;
  const currentAngle = speedToAngle(speed);

  const theme =
    phase === "upload"
      ? { id: "uploadGaugeProgress", stops: ["#d8b4fe", "#a855f7", "#7e22ce"], text: t.upload, textColor: "#7e22ce" }
      : phase === "download"
      ? { id: "downloadGaugeProgress", stops: ["#93c5fd", "#3b82f6", "#1d4ed8"], text: t.download, textColor: "#2563eb" }
      : { id: "idleGaugeProgress", stops: ["#cbd5e1", "#94a3b8", "#64748b"], text: phase === "discover" ? "PING" : "", textColor: "#64748b" };

  const ticks = useMemo(() => {
    return TICK_VALUES.map((value, index) => {
      const angle = speedToAngle(value);
      const major = TICK_LABEL_VALUES.includes(value);
      const outer = polarToCartesian(centerX, centerY, major ? radius + 4 : radius + 1, angle);
      const inner = polarToCartesian(centerX, centerY, major ? radius - 17 : radius - 9, angle);
      return { index, value, major, x1: outer.x, y1: outer.y, x2: inner.x, y2: inner.y };
    });
  }, []);

  return (
    <div className="mx-auto w-full max-w-[560px]">
      <svg viewBox="0 0 440 340" className={cn("cnspeed-gauge block w-full transition", phase === "download" || phase === "upload" || phase === "discover" ? "drop-shadow-sm" : "")} role="img" aria-label={t.speedGauge}>
        <defs>
          <linearGradient id={theme.id} x1="70" y1="205" x2="370" y2="205" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor={theme.stops[0]} />
            <stop offset="0.48" stopColor={theme.stops[1]} />
            <stop offset="1" stopColor={theme.stops[2]} />
          </linearGradient>
        </defs>
        <path className="cnspeed-gauge-track" d={describeArc(centerX, centerY, radius, -115, 115)} fill="none" stroke="currentColor" strokeWidth="18" strokeLinecap="round" />
        {speed > 1 ? (
          <path d={describeArc(centerX, centerY, radius, -115, currentAngle)} fill="none" stroke={`url(#${theme.id})`} strokeWidth="18" strokeLinecap="round" />
        ) : null}
        {phase === "discover" ? (
          <g opacity="0.9">
            <path d={describeArc(centerX, centerY, radius - 1, -115, 115)} fill="none" stroke={`url(#${theme.id})`} strokeWidth="12" strokeLinecap="round" strokeDasharray="42 430">
              <animate attributeName="stroke-dashoffset" from="0" to="-472" dur="1.15s" repeatCount="indefinite" />
            </path>
          </g>
        ) : null}
        {ticks.map((tick) => (
          <line key={tick.index} className={tick.major ? "cnspeed-gauge-tick-major" : "cnspeed-gauge-tick"} x1={tick.x1} y1={tick.y1} x2={tick.x2} y2={tick.y2} stroke="currentColor" strokeWidth={tick.major ? 2 : 1} strokeLinecap="round" />
        ))}
        {TICK_LABEL_VALUES.map((value) => {
          const point = polarToCartesian(centerX, centerY, radius - 41, speedToAngle(value));
          return (
            <text key={value} className="cnspeed-gauge-tick-label" x={point.x} y={point.y + 5} textAnchor="middle" fill="currentColor" fontSize="13" fontWeight="600">
              {formatTickLabel(value)}
            </text>
          );
        })}
        {theme.text ? (
          <text x={centerX} y="120" textAnchor="middle" fill="currentColor" className={cn("cnspeed-gauge-phase-label", phase === "upload" ? "cnspeed-gauge-upload" : phase === "download" ? "cnspeed-gauge-download" : "cnspeed-gauge-idle")} fontSize="13" fontWeight="700">
            {theme.text}
          </text>
        ) : null}
        <text x={centerX} y="190" textAnchor="middle" fill="currentColor" className="cnspeed-gauge-value" fontSize="46" fontWeight="700">
          {formatSpeed(speed)}
        </text>
        <text x={centerX} y="220" textAnchor="middle" fill="currentColor" className={cn("cnspeed-gauge-unit", phase === "upload" ? "cnspeed-gauge-upload" : phase === "download" ? "cnspeed-gauge-download" : "cnspeed-gauge-idle")} fontSize="17" fontWeight="700">
          Mbps
        </text>
      </svg>
    </div>
  );
}

function ResultStatsCard({ title, accentClass, peakSpeed, avgSpeed, usedBytes, t, locale }) {
  return (
    <Surface className="p-5">
      <div className={cn("text-sm font-bold", accentClass)}>{title}</div>
      <div className="mt-4 grid grid-cols-3 gap-3">
        <div>
          <div className="text-xs uppercase tracking-wide text-slate-500">{t.max}</div>
          <div className="mt-1 text-xl font-semibold text-slate-950">{formatSpeed(peakSpeed)}</div>
          <div className="text-xs text-slate-500">Mbps</div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-wide text-slate-500">{t.avg}</div>
          <div className="mt-1 text-xl font-semibold text-slate-950">{formatSpeed(avgSpeed)}</div>
          <div className="text-xs text-slate-500">Mbps</div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-wide text-slate-500">{t.used}</div>
          <div className="mt-1 text-xl font-semibold text-slate-950">{formatDataFromBytes(usedBytes, locale)}</div>
          <div className="text-xs text-slate-500">{t.traffic}</div>
        </div>
      </div>
    </Surface>
  );
}

function ErrorBanner({ message, t }) {
  if (!message) return null;
  return (
    <div className="mt-5 rounded-[24px] border border-red-200 bg-red-50 px-5 py-4 text-red-800 shadow-sm">
      <div className="text-sm font-bold">{t.errorTitle}</div>
      <div className="mt-1 break-words text-sm font-medium">{message}</div>
      <div className="mt-1 text-xs text-red-700/80">{t.errorHint}</div>
    </div>
  );
}

function PrivacyButton({ hidden, onToggle, t }) {
  return (
    <button
      type="button"
      onClick={onToggle}
      className="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-slate-50 text-slate-500 transition hover:bg-slate-100 hover:text-slate-800"
      aria-label={hidden ? t.showSensitive : t.hideSensitive}
      title={hidden ? t.showSensitive : t.hideSensitive}
    >
      <IconEye hidden={hidden} className="h-5 w-5" />
    </button>
  );
}

function NodeSettingsModal({
  open,
  onClose,
  t,
  nodeMode,
  setNodeMode,
  availableNodes,
  selectedNodeIndex,
  setSelectedNodeIndex,
  nodesLoading,
  loadNodes,
}) {
  const [nodeSearch, setNodeSearch] = useState("");
  const nodeQuery = nodeSearch.trim().toLowerCase();
  const visibleNodes = useMemo(() => {
    if (!nodeQuery) return availableNodes.map((node, index) => ({ node, index }));
    return availableNodes
      .map((node, index) => ({ node, index }))
      .filter(({ node }) => {
        const text = [
          node.name,
          node.host,
          node.port,
          node.hostid,
          node.province,
          node.city,
          node.operator,
        ]
          .filter(Boolean)
          .join(" ")
          .toLowerCase();
        return text.includes(nodeQuery);
      });
  }, [availableNodes, nodeQuery]);
  const countText = nodeQuery
    ? (t.nodeSearchCount || "{shown} / {total}").replace("{shown}", visibleNodes.length).replace("{total}", availableNodes.length)
    : (t.nodeCount || "{count}").replace("{count}", availableNodes.length);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-slate-950/40 px-4 py-5 backdrop-blur-sm sm:items-center">
      <div className="w-full max-w-lg rounded-[28px] bg-white p-5 shadow-2xl sm:p-6" role="dialog" aria-modal="true" aria-label={t.nodeSettings}>
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-lg font-bold text-slate-950">{t.nodeSettings}</div>
            <div className="mt-1 text-sm text-slate-500">{t.nodeMode}</div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-slate-100 text-xl font-semibold leading-none text-slate-500 transition hover:bg-slate-200 hover:text-slate-800"
            aria-label={t.complete}
            title={t.complete}
          >
            ×
          </button>
        </div>

        <div className="mt-5 grid grid-cols-2 gap-2 rounded-full bg-slate-100 p-1">
          <button
            type="button"
            onClick={() => setNodeMode("auto")}
            className={cn("h-10 rounded-full px-4 text-sm font-bold transition", nodeMode === "auto" ? "bg-white text-blue-700 shadow-sm" : "text-slate-500 hover:text-slate-800")}
          >
            {t.autoNode}
          </button>
          <button
            type="button"
            onClick={() => {
              setNodeMode("manual");
              if (availableNodes.length === 0) loadNodes();
            }}
            className={cn("h-10 rounded-full px-4 text-sm font-bold transition", nodeMode === "manual" ? "bg-white text-blue-700 shadow-sm" : "text-slate-500 hover:text-slate-800")}
          >
            {t.manualNode}
          </button>
        </div>

        <div className="mt-5">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
            <div className="relative flex-1">
              <input
                value={nodeSearch}
                onChange={(event) => setNodeSearch(event.target.value)}
                placeholder={t.searchNodes}
                className="h-11 w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 text-sm font-semibold text-slate-800 outline-none transition placeholder:text-slate-400 focus:border-blue-300 focus:bg-white focus:ring-4 focus:ring-blue-100"
              />
            </div>
            <button
              type="button"
              onClick={loadNodes}
              disabled={nodesLoading}
              className="h-11 rounded-full bg-blue-50 px-4 text-sm font-bold text-blue-700 transition hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {nodesLoading ? t.loadingNodes : t.loadNodes}
            </button>
          </div>
          <div className="mt-2 text-xs font-semibold text-slate-400">{countText}</div>

          <div className="mt-4 max-h-[42vh] overflow-y-auto pr-1">
            {visibleNodes.length > 0 ? (
              <div className="grid gap-2 sm:grid-cols-2">
                {visibleNodes.map(({ node, index }) => (
                  <button
                    key={`${node.host}:${node.port}:${index}`}
                    type="button"
                    onClick={() => {
                      setNodeMode("manual");
                      setSelectedNodeIndex(index);
                    }}
                    className={cn(
                      "min-h-11 rounded-2xl px-4 py-2 text-left text-sm font-semibold transition",
                      selectedNodeIndex === index && nodeMode === "manual" ? "bg-blue-600 text-white" : "bg-slate-50 text-slate-700 hover:bg-slate-100"
                    )}
                  >
                    <span className="flex items-center gap-2">
                      <span className="block min-w-0 flex-1 break-words">{node.name}</span>
                      {node.recommended ? <span className={cn("shrink-0 rounded-full px-2 py-0.5 text-[11px] font-bold", selectedNodeIndex === index && nodeMode === "manual" ? "bg-white/20 text-white" : "bg-blue-50 text-blue-700")}>{t.recommendedNode}</span> : null}
                    </span>
                    <span className={cn("mt-1 block truncate text-xs font-medium", selectedNodeIndex === index && nodeMode === "manual" ? "text-blue-100" : "text-slate-400")}>
                      {[node.province, node.city, node.operator].filter(Boolean).join(" · ") || `${node.host}:${node.port}`}
                    </span>
                  </button>
                ))}
              </div>
            ) : (
              <div className="rounded-2xl bg-slate-50 px-4 py-6 text-center text-sm font-medium text-slate-500">
                {nodesLoading ? t.loadingNodes : t.noNodes}
              </div>
            )}
          </div>
        </div>

        <FilledButton type="button" onClick={onClose} className="mt-5 w-full">
          {t.complete}
        </FilledButton>
      </div>
    </div>
  );
}

function UserInfoCard({ ipInfo, networkType, t, privacyHidden, onTogglePrivacy }) {
  const hasError = Boolean(ipInfo?.error);
  const ip = hasError ? t.unavailable : ipInfo?.ip || t.loading;
  const location = hasError ? t.unavailable : ipInfo?.location || t.loading;
  const carrier = hasError ? t.unavailable : ipInfo?.carrier || t.loading;
  const networkLabel = networkType || t.unknown;
  return (
    <Surface className="p-5">
      <div className="flex items-start gap-4">
        <div className="grid h-12 w-12 shrink-0 place-items-center rounded-2xl bg-emerald-50 text-emerald-700">
          <IconMapPin className="h-7 w-7" />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-3">
            <div className="text-sm font-medium text-slate-500">{t.userInfo}</div>
            <div className="flex shrink-0 items-center gap-2">
              <span className="cnspeed-network-badge" title={t.networkType}>{networkLabel}</span>
              <PrivacyButton hidden={privacyHidden} onToggle={onTogglePrivacy} t={t} />
            </div>
          </div>
          <div className="mt-3 space-y-2 text-sm">
            <div className="flex items-center justify-between gap-3">
              <span className="text-slate-500">{t.userIp}</span>
              <span className="truncate font-semibold text-slate-950">{privacyHidden && !hasError ? maskText(ip, 8) : ip}</span>
            </div>
            <div className="flex items-center justify-between gap-3">
              <span className="text-slate-500">{t.region}</span>
              <span className="truncate font-semibold text-slate-950">{privacyHidden && !hasError ? maskText(location, 4) : location}</span>
            </div>
            <div className="flex items-center justify-between gap-3">
              <span className="text-slate-500">{t.carrier}</span>
              <span className="truncate font-semibold text-slate-950">{carrier}</span>
            </div>
          </div>
        </div>
      </div>
    </Surface>
  );
}

function SpeedChart({ title, accent, points, active, stats, phaseLabel, t, locale }) {
  const width = 420;
  const height = 170;
  const paddingX = 14;
  const paddingY = 18;
  const displayPoints = useMemo(() => {
    if (active || points.length < 4) return points;
    const maxValue = Math.max(...points.map((p) => Number(p.mbps) || 0));
    const last = Number(points[points.length - 1]?.mbps) || 0;
    const previous = Number(points[points.length - 2]?.mbps) || 0;
    if (maxValue > 0 && previous > maxValue * 0.25 && last < maxValue * 0.08) {
      return points.slice(0, -1);
    }
    return points;
  }, [points, active]);

  const maxY = useMemo(() => {
    const pointMax = displayPoints.length ? Math.max(...displayPoints.map((p) => Number(p.mbps) || 0)) : 0;
    return Math.max(pointMax, 100);
  }, [displayPoints]);

  const linePath = useMemo(() => {
    if (displayPoints.length === 0) return "";
    const lastT = Math.max(1, Number(displayPoints[displayPoints.length - 1].t) || displayPoints.length);
    return displayPoints
      .map((point, index) => {
        const x = paddingX + ((Number(point.t) || index) / lastT) * (width - paddingX * 2);
        const y = height - paddingY - ((Number(point.mbps) || 0) / maxY) * (height - paddingY * 2);
        return `${index === 0 ? "M" : "L"} ${x} ${y}`;
      })
      .join(" ");
  }, [displayPoints, maxY]);

  const areaPath = useMemo(() => {
    if (displayPoints.length === 0 || !linePath) return "";
    const firstX = paddingX;
    const lastT = Math.max(1, Number(displayPoints[displayPoints.length - 1].t) || displayPoints.length);
    const lastX = paddingX + ((Number(displayPoints[displayPoints.length - 1].t) || displayPoints.length) / lastT) * (width - paddingX * 2);
    return `${linePath} L ${lastX} ${height - paddingY} L ${firstX} ${height - paddingY} Z`;
  }, [displayPoints, linePath]);

  return (
    <Surface className="p-5">
      <div className="mb-4 flex items-center justify-between gap-3">
        <div>
          <div className={cn("text-sm font-bold", accent)}>{title}</div>
          <div className="mt-1 text-xs text-slate-500">{phaseLabel}</div>
        </div>
        <div className={cn("rounded-full px-3 py-1 text-xs font-semibold", active ? "bg-slate-100 text-slate-700" : "bg-slate-50 text-slate-400")}>
          {active ? t.live : t.idle}
        </div>
      </div>
      <div className="overflow-hidden rounded-2xl border border-slate-200 bg-slate-50">
        <svg viewBox={`0 0 ${width} ${height}`} className="block w-full">
          {[0.25, 0.5, 0.75].map((g) => {
            const y = paddingY + g * (height - paddingY * 2);
            return <line key={g} x1={paddingX} y1={y} x2={width - paddingX} y2={y} stroke="#e2e8f0" strokeWidth="1" strokeDasharray="4 4" />;
          })}
          {displayPoints.length > 0 ? (
            <>
              <path d={areaPath} fill="currentColor" className={cn("opacity-10", accent)} />
              <path d={linePath} fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className={accent} />
            </>
          ) : (
            <text x={width / 2} y={height / 2} textAnchor="middle" fill="#94a3b8" fontSize="14" fontWeight="600">
              {t.noDataYet}
            </text>
          )}
        </svg>
      </div>
      <div className="mt-4 grid grid-cols-3 gap-3">
        <div>
          <div className="text-xs uppercase tracking-wide text-slate-500">{t.max}</div>
          <div className="mt-1 text-lg font-semibold text-slate-950">{formatSpeed(stats.peak)}</div>
          <div className="text-xs text-slate-500">Mbps</div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-wide text-slate-500">{t.avg}</div>
          <div className="mt-1 text-lg font-semibold text-slate-950">{formatSpeed(stats.avg)}</div>
          <div className="text-xs text-slate-500">Mbps</div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-wide text-slate-500">{t.used}</div>
          <div className="mt-1 text-lg font-semibold text-slate-950">{formatDataFromBytes(stats.bytes, locale)}</div>
          <div className="text-xs text-slate-500">{t.traffic}</div>
        </div>
      </div>
    </Surface>
  );
}

function SpeedtestPage() {
  const [locale, setLocale] = useState("zh");
  const [job, setJob] = useState(null);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState("");
  const [ipInfo, setIpInfo] = useState(null);
  const [privacyHidden, setPrivacyHidden] = useState(false);
  const [nodeMode, setNodeMode] = useState("auto");
  const [availableNodes, setAvailableNodes] = useState([]);
  const [selectedNodeIndex, setSelectedNodeIndex] = useState(-1);
  const [nodesLoading, setNodesLoading] = useState(false);
  const [nodeSettingsOpen, setNodeSettingsOpen] = useState(false);
  const [displaySpeed, setDisplaySpeed] = useState(0);
  const [currentJobId, setCurrentJobId] = useState("");
  const [appInfo, setAppInfo] = useState(DEFAULT_APP_INFO);
  const [aboutOpen, setAboutOpen] = useState(false);
  const [themeMode, setThemeMode] = useState(initialThemeMode);
  const [updateInfo, setUpdateInfo] = useState(null);
  const [updateChecking, setUpdateChecking] = useState(false);
  const [announcementOpen, setAnnouncementOpen] = useState(false);
  const [networkType, setNetworkType] = useState("");
  const [reportId, setReportId] = useState("");
  const pollRef = useRef(null);
  const gaugeFrameRef = useRef(null);
  const gaugeSpeedRef = useRef(0);
  const reportedJobsRef = useRef(new Set());
  const autoAnnouncementShownRef = useRef(false);
  const t = LOCALES[locale];

  const phase = phaseFromJob(job);
  const summary = job?.summary || {};
  const samples = job?.samples || {};
  const downloadSeries = samples.download || [];
  const uploadSeries = samples.upload || [];

  const downloadStats = {
    avg: Number(summary.download_mbps) || averageFromSeries(downloadSeries),
    peak: Number(summary.download_peak_mbps) || peakFromSeries(downloadSeries),
    bytes: Number(summary.download_bytes) || Number(downloadSeries[downloadSeries.length - 1]?.bytes) || 0,
  };
  const uploadStats = {
    avg: Number(summary.upload_mbps) || averageFromSeries(uploadSeries),
    peak: Number(summary.upload_peak_mbps) || peakFromSeries(uploadSeries),
    bytes: Number(summary.upload_bytes) || Number(uploadSeries[uploadSeries.length - 1]?.bytes) || 0,
  };

  const liveSpeed =
    running && Number(summary.live_mbps)
      ? Number(summary.live_mbps)
      : phase === "upload"
      ? uploadStats.avg
      : phase === "download"
      ? downloadStats.avg
      : job?.status === "done"
      ? downloadStats.avg || uploadStats.avg
      : 0;

  const ping = Number(summary.latency_avg_ms) || 0;
  const jitter =
    summary.latency_max_ms != null && summary.latency_min_ms != null
      ? Math.max(0, Number(summary.latency_max_ms) - Number(summary.latency_min_ms))
      : 0;
  const totalBytes = downloadStats.bytes + uploadStats.bytes;
  const quality = t[qualityKey(downloadStats.peak, uploadStats.peak, ping, jitter)];
  const errorMessage = error || (job?.status === "error" ? job?.message : "");
  const togglePrivacy = () => setPrivacyHidden((hidden) => !hidden);
  const selectedNode = selectedNodeIndex >= 0 ? availableNodes[selectedNodeIndex] : null;
  const displayNode = displayNodeName(job, nodeMode, selectedNode, t.manualNode);
  const visibleNodeName = privacyHidden ? maskWithCarrier(displayNode, ipInfo?.carrier) : displayNode;

  const phaseTitle =
    phase === "download"
      ? t.downloading
      : phase === "upload"
      ? t.uploading
      : phase === "cancelled"
      ? job?.status === "cancelled"
        ? t.cancelled
        : t.stopping
      : phase === "discover"
      ? t.discovering
      : phase === "error"
      ? t.failed
      : job?.status === "done"
      ? t.resultReady
      : t.readyToStart;

  const phaseBadge = phase === "upload" ? t.upload : phase === "download" ? t.download : phase === "cancelled" ? t.cancelled : phase === "error" ? t.error : quality;

  useEffect(() => {
    loadIpInfo();
    loadAppInfoAndCheck();
    return () => {
      if (pollRef.current) window.clearInterval(pollRef.current);
      if (gaugeFrameRef.current) window.cancelAnimationFrame(gaugeFrameRef.current);
    };
  }, []);

  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const applyTheme = () => {
      const resolved = themeMode === "system" ? (media.matches ? "dark" : "light") : themeMode;
      document.documentElement.setAttribute("data-theme", resolved);
      document.documentElement.style.colorScheme = resolved;
    };
    applyTheme();
    media.addEventListener?.("change", applyTheme);
    return () => media.removeEventListener?.("change", applyTheme);
  }, [themeMode]);

  useEffect(() => {
    const ip = ipInfo?.ip;
    if (!ip) {
      setNetworkType("");
      return;
    }
    loadNetworkType(ip);
  }, [ipInfo?.ip]);

  useEffect(() => {
    if (gaugeFrameRef.current) window.cancelAnimationFrame(gaugeFrameRef.current);
    const target = Number(liveSpeed) || 0;
    let last = performance.now();

    function animate(now) {
      const dt = Math.min(48, now - last);
      last = now;
      const current = gaugeSpeedRef.current;
      const diff = target - current;
      const easing = target > current ? 0.16 : 0.11;
      const next = Math.abs(diff) < 0.08 ? target : current + diff * easing * (dt / 16.67);
      gaugeSpeedRef.current = next;
      setDisplaySpeed(next);
      if (Math.abs(target - next) >= 0.08) {
        gaugeFrameRef.current = window.requestAnimationFrame(animate);
      }
    }

    gaugeFrameRef.current = window.requestAnimationFrame(animate);
    return () => {
      if (gaugeFrameRef.current) window.cancelAnimationFrame(gaugeFrameRef.current);
    };
  }, [liveSpeed]);

  async function loadIpInfo() {
    try {
      const response = await fetch("/api/ip-info");
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || "ip info failed");
      setIpInfo(data);
    } catch (err) {
      setIpInfo({ error: err.message || String(err) });
    }
  }

  async function loadAppInfoAndCheck() {
    let info = DEFAULT_APP_INFO;
    try {
      info = { ...DEFAULT_APP_INFO, ...(await fetchJSONWithTimeout("/api/app-info", {}, 3000)) };
      setAppInfo(info);
    } catch (err) {
      setAppInfo(DEFAULT_APP_INFO);
    }
    checkUpdate(false, info);
  }

  async function checkUpdate(manual = false, info = appInfo) {
    if (manual) setUpdateChecking(true);
    const params = new URLSearchParams({
      platform: info.platform || "desktop",
      version: info.version || APP_VERSION,
      version_code: String(info.version_code || APP_VERSION_CODE),
      channel: "stable",
      machine_id: info.machine_id || "",
    });
    try {
      const data = await fetchJSONWithTimeout(`/api/client-check?${params.toString()}`, {}, 3000);
      setUpdateInfo(data);
      const latest = data?.latest;
      const hasUpdate = Boolean(data?.has_update || (latest?.version && latest.version !== (info.version || APP_VERSION)));
      const hasAnnouncements = Array.isArray(data?.announcements) && data.announcements.length > 0;
      if ((manual || !autoAnnouncementShownRef.current) && (data?.blocked || hasUpdate || hasAnnouncements)) {
        autoAnnouncementShownRef.current = true;
        setAnnouncementOpen(true);
      }
      return data;
    } catch (err) {
      if (manual) setUpdateInfo(null);
      return null;
    } finally {
      if (manual) setUpdateChecking(false);
    }
  }

  async function loadNetworkType(ip) {
    try {
      const params = new URLSearchParams({ ip });
      const data = await fetchJSONWithTimeout(`/api/network-type?${params.toString()}`, {}, 3000);
      setNetworkType(data.network_type || data.netWorkType || t.unknown);
    } catch (err) {
      setNetworkType(t.unknown);
    }
  }

  function toggleThemeMode() {
    const next = themeMode === "system" ? "dark" : themeMode === "dark" ? "light" : "system";
    setThemeMode(next);
    window.localStorage.setItem("cnspeed_theme", next);
  }

  async function loadNodes() {
    setNodesLoading(true);
    setError("");
    try {
      const response = await fetch("/api/nodes");
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || "load nodes failed");
      setAvailableNodes(data.nodes || []);
      if ((data.nodes || []).length > 0) setSelectedNodeIndex(0);
    } catch (err) {
      setError(err.message || String(err));
    } finally {
      setNodesLoading(false);
    }
  }

  function openNodeSettings() {
    setNodeSettingsOpen(true);
    if (availableNodes.length === 0) loadNodes();
  }

  async function startTest() {
    if (pollRef.current) window.clearInterval(pollRef.current);
    setError("");
    if (nodeMode === "manual" && !selectedNode) {
      setError(t.selectNodeFirst);
      return;
    }
    setRunning(true);
    setCurrentJobId("");
    setReportId("");
    gaugeSpeedRef.current = 0;
    setDisplaySpeed(0);
    setJob({
      status: "running",
      stage: t.discovering,
      summary: {},
      samples: {},
      result: {},
      nodes: [],
      logs: [],
    });

    const config = {
      auto: nodeMode !== "manual",
      host: selectedNode?.host || "",
      port: selectedNode?.port || 0,
      manualName: selectedNode?.name || "manual",
      probeCount: 10,
      autoValidateOrder: "list",
      duration: 15,
      sampleInterval: 0.25,
      downloadThreads: 16,
      uploadThreads: 8,
      runDownload: true,
      runUpload: true,
      downloadProbe: true,
      forceDownload: false,
      bandwidth: 2000,
      downloadMode: "raw",
      probeOnly: false,
    };

    try {
      const response = await fetch("/api/start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(config),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || "start failed");
      setCurrentJobId(data.job_id);
      pollRef.current = window.setInterval(() => pollJob(data.job_id), 300);
      pollJob(data.job_id);
    } catch (err) {
      setRunning(false);
      setError(err.message || String(err));
      setJob((current) => ({ ...current, status: "error", stage: t.failed, message: err.message || String(err) }));
    }
  }

  async function pollJob(jobId) {
    try {
      const response = await fetch(`/api/status?id=${encodeURIComponent(jobId)}`);
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || "poll failed");
      setJob(data);
      if (data.status === "done" || data.status === "error" || data.status === "cancelled") {
        if (pollRef.current) window.clearInterval(pollRef.current);
        pollRef.current = null;
        setRunning(false);
        setCurrentJobId("");
        if (data.status === "error") setError(data.message || t.failed);
        if (data.status === "done") submitReport(data);
      }
    } catch (err) {
      if (pollRef.current) window.clearInterval(pollRef.current);
      pollRef.current = null;
      setRunning(false);
      setCurrentJobId("");
      setError(err.message || String(err));
    }
  }

  async function cancelTest() {
    if (!currentJobId) return;
    try {
      await fetch("/api/cancel", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: currentJobId }),
      });
      setJob((current) => ({ ...(current || {}), status: "cancelling", stage: t.stopping, message: t.stopping }));
    } catch (err) {
      setError(err.message || String(err));
    }
  }

  async function submitReport(doneJob) {
    const jobId = doneJob?.id || doneJob?.created_at || currentJobId;
    if (!jobId || reportedJobsRef.current.has(jobId)) return;
    reportedJobsRef.current.add(jobId);
    const doneSummary = doneJob?.summary || {};
    const doneSamples = doneJob?.samples || {};
    const doneDownloadSeries = doneSamples.download || [];
    const doneUploadSeries = doneSamples.upload || [];
    const doneDownload = {
      avg: Number(doneSummary.download_mbps) || averageFromSeries(doneDownloadSeries),
      peak: Number(doneSummary.download_peak_mbps) || peakFromSeries(doneDownloadSeries),
      bytes: Number(doneSummary.download_bytes) || Number(doneDownloadSeries[doneDownloadSeries.length - 1]?.bytes) || 0,
    };
    const doneUpload = {
      avg: Number(doneSummary.upload_mbps) || averageFromSeries(doneUploadSeries),
      peak: Number(doneSummary.upload_peak_mbps) || peakFromSeries(doneUploadSeries),
      bytes: Number(doneSummary.upload_bytes) || Number(doneUploadSeries[doneUploadSeries.length - 1]?.bytes) || 0,
    };
    const nodeName = displayNodeName(doneJob, nodeMode, selectedNode, t.manualNode);
    const payload = {
      machine_id: appInfo.machine_id || "",
      app_version: appInfo.version || APP_VERSION,
      platform: appInfo.platform || "desktop",
      device: {
        model: navigator.userAgent || "",
        os: navigator.platform || "",
        arch: navigator.userAgentData?.platform || "",
      },
      network: {
        ip: ipInfo?.ip || "",
        province: ipInfo?.province || "",
        city: ipInfo?.city || "",
        isp: ipInfo?.carrier || "",
        type: networkType || t.unknown,
      },
      speedtest: {
        node: nodeName,
        ping_ms: Number(doneSummary.latency_avg_ms) || 0,
        jitter_ms:
          doneSummary.latency_max_ms != null && doneSummary.latency_min_ms != null
            ? Math.max(0, Number(doneSummary.latency_max_ms) - Number(doneSummary.latency_min_ms))
            : 0,
        download_mbps: doneDownload.avg,
        download_peak_mbps: doneDownload.peak,
        upload_mbps: doneUpload.avg,
        upload_peak_mbps: doneUpload.peak,
        download_bytes: doneDownload.bytes,
        upload_bytes: doneUpload.bytes,
      },
    };
    try {
      const data = await fetchJSONWithTimeout(
        "/api/report",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        },
        3000
      );
      if (data.report_id) setReportId(data.report_id);
    } catch (err) {}
  }

  async function shutdownApp() {
    if (!window.confirm(t.exitConfirm)) return;
    try {
      await fetch("/api/shutdown", { method: "POST" });
      window.alert(t.exitNotice);
      setRunning(false);
      setError("");
      setJob((current) => ({
        ...(current || {}),
        status: "done",
        stage: t.exitApp,
        message: t.exitApp,
      }));
    } catch (err) {
      setError(err.message || String(err));
    }
  }

  return (
    <main className="min-h-screen bg-[#f6f7fb] text-slate-950">
      <div className="mx-auto max-w-7xl px-4 py-5 sm:px-6 lg:px-8">
        <header className="flex flex-col gap-4 rounded-[30px] border border-slate-200/80 bg-white px-4 py-4 shadow-sm sm:flex-row sm:items-center sm:justify-between sm:px-6">
          <div className="flex items-center gap-3 text-left">
            <div className="grid h-12 w-12 place-items-center rounded-2xl bg-blue-50 text-blue-700">
              <IconSpeed className="h-8 w-8" />
            </div>
            <div>
              <div className="text-lg font-bold tracking-tight sm:text-xl">{t.appTitle}</div>
              <div className="text-sm text-slate-500">{t.appSubtitle}</div>
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <LanguageSwitch locale={locale} setLocale={setLocale} t={t} />
            <ThemeButton mode={themeMode} onToggle={toggleThemeMode} t={t} />
            <button
              type="button"
              onClick={() => setAboutOpen(true)}
              className="h-10 rounded-full bg-slate-100 px-4 text-sm font-bold text-slate-600 transition hover:bg-slate-200 hover:text-slate-900"
            >
              {t.about}
            </button>
            {appInfo.platform !== "openwrt" ? (
              <button
                type="button"
                onClick={shutdownApp}
                className="h-10 rounded-full bg-red-50 px-4 text-sm font-bold text-red-700 transition hover:bg-slate-100"
              >
                {t.exitApp}
              </button>
            ) : null}
          </div>
        </header>

        <div className="cnspeed-router-notice" role="note">
          {t.routerSpeedNotice}
        </div>

        <section className="mt-5 grid grid-cols-2 gap-4 lg:grid-cols-4">
          <MetricCard label={t.ping} value={ping ? ping.toFixed(1) : "--"} unit="ms" helper={t.roundTripLatency} />
          <MetricCard label={t.jitter} value={jitter ? jitter.toFixed(1) : "--"} unit="ms" helper={t.latencyVariation} />
          <MetricCard label={t.totalData} value={formatDataFromBytes(totalBytes, locale)} unit="" helper={t.totalTrafficHelper} />
          <MetricCard label={t.quality} value={quality} unit="" helper={errorMessage || t.overallEvaluation} />
        </section>

        <ErrorBanner message={errorMessage} t={t} />

        <section className="mt-5 grid gap-5 lg:grid-cols-[minmax(0,1.45fr)_minmax(320px,0.75fr)]">
          <Surface className="cnspeed-phase-card p-5 sm:p-7">
            <div className="flex flex-col items-center">
              <div className="mb-3 flex w-full flex-wrap items-center justify-between gap-3">
                <div>
                  <div className="text-sm font-semibold text-slate-500">{t.currentPhase}</div>
                  <div className="mt-1 text-2xl font-bold tracking-tight text-slate-950">{phaseTitle}</div>
                </div>
                <div className={cn("rounded-full px-4 py-2 text-sm font-bold", phase === "upload" ? "bg-purple-50 text-purple-700" : phase === "download" ? "bg-blue-50 text-blue-700" : phase === "error" ? "bg-red-50 text-red-700" : "bg-emerald-50 text-emerald-700")}>
                  {phaseBadge}
                </div>
              </div>

              <Gauge speed={displaySpeed} phase={phase} t={t} />

              <div className="mt-1 flex flex-wrap items-center justify-center gap-3">
                <FilledButton type="button" onClick={startTest} disabled={running}>
                  {running ? t.testing : job?.status === "done" || job?.status === "error" || job?.status === "cancelled" ? t.restartTest : t.startTest}
                </FilledButton>
                {running ? (
                  <button
                    type="button"
                    onClick={cancelTest}
                    className="inline-flex h-12 items-center justify-center rounded-full bg-red-50 px-6 text-sm font-bold text-red-700 transition hover:bg-red-100 disabled:cursor-not-allowed disabled:opacity-60"
                    disabled={job?.status === "cancelling"}
                  >
                    {job?.status === "cancelling" ? t.stopping : t.stopTest}
                  </button>
                ) : null}
              </div>
            </div>
            {reportId ? <div className="cnspeed-report-id">{reportId}</div> : null}
          </Surface>

          <aside className="space-y-4">
            <ResultStatsCard title={t.downloadResult} accentClass="text-blue-700" peakSpeed={downloadStats.peak} avgSpeed={downloadStats.avg} usedBytes={downloadStats.bytes} t={t} locale={locale} />
            <ResultStatsCard title={t.uploadResult} accentClass="text-purple-700" peakSpeed={uploadStats.peak} avgSpeed={uploadStats.avg} usedBytes={uploadStats.bytes} t={t} locale={locale} />
            <Surface className="p-5">
              <div className="flex items-start gap-4">
                <div className="grid h-12 w-12 shrink-0 place-items-center rounded-2xl bg-blue-50 text-blue-700">
                  <IconServer className="h-7 w-7" />
                </div>
                <div className="min-w-0 flex-1">
                  <div className="flex items-start justify-between gap-3">
                    <div className="text-sm font-medium text-slate-500">{t.server}</div>
                    <div className="flex shrink-0 items-center gap-2">
                      <button
                        type="button"
                        onClick={openNodeSettings}
                        className="h-10 rounded-full bg-slate-50 px-4 text-sm font-bold text-slate-600 transition hover:bg-slate-100 hover:text-slate-900"
                      >
                        {t.nodeSettings}
                      </button>
                      <PrivacyButton hidden={privacyHidden} onToggle={togglePrivacy} t={t} />
                    </div>
                  </div>
                  <div className="mt-1 truncate text-lg font-semibold text-slate-950">{visibleNodeName}</div>
                </div>
              </div>
            </Surface>
            <UserInfoCard ipInfo={ipInfo} networkType={networkType || t.unknown} t={t} privacyHidden={privacyHidden} onTogglePrivacy={togglePrivacy} />
          </aside>
        </section>

        <section className="mt-5 grid gap-5 lg:grid-cols-2">
          <SpeedChart title={t.downloadCurve} accent="text-blue-600" points={downloadSeries} active={phase === "download"} phaseLabel={t.downloadCurveDesc} stats={downloadStats} t={t} locale={locale} />
          <SpeedChart title={t.uploadCurve} accent="text-purple-600" points={uploadSeries} active={phase === "upload"} phaseLabel={t.uploadCurveDesc} stats={uploadStats} t={t} locale={locale} />
        </section>
      </div>
      <NodeSettingsModal
        open={nodeSettingsOpen}
        onClose={() => setNodeSettingsOpen(false)}
        t={t}
        nodeMode={nodeMode}
        setNodeMode={setNodeMode}
        availableNodes={availableNodes}
        selectedNodeIndex={selectedNodeIndex}
        setSelectedNodeIndex={setSelectedNodeIndex}
        nodesLoading={nodesLoading}
        loadNodes={loadNodes}
      />
      <AboutModal
        open={aboutOpen}
        onClose={() => setAboutOpen(false)}
        t={t}
        appInfo={appInfo}
        updateInfo={updateInfo}
        updateChecking={updateChecking}
        onCheckUpdate={() => checkUpdate(true)}
      />
      <AnnouncementModal
        open={announcementOpen}
        onClose={() => setAnnouncementOpen(false)}
        t={t}
        updateInfo={updateInfo}
        appInfo={appInfo}
      />
    </main>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<SpeedtestPage />);
