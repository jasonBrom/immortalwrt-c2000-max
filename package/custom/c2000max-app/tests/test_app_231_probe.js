"use strict";

// Exact protocol-selection predicates recovered from 鲲鹏无限 2.3.1.
function normalize(value) {
  return value;
}

function signalList(value) {
  const body = normalize(value);
  if (body && Array.isArray(body.signal)) return body.signal;
  if (body && body.result && Array.isArray(body.result.signal)) {
    return body.result.signal;
  }
  return [];
}

function signalIdentity(value) {
  const first = signalList(value)[0];
  if (!first || typeof first !== "object") return "";
  if (first.mac !== undefined && first.mac !== null) {
    return String(first.mac || "").trim();
  }
  if (first.id !== undefined && first.id !== null) {
    return String(first.id || "").trim();
  }
  return "";
}

function isLegacyEnvelope(value) {
  const body = normalize(value);
  return Boolean(
    body &&
      typeof body === "object" &&
      typeof body.data === "string" &&
      !Array.isArray(body.signal) &&
      !(body.result && Array.isArray(body.result.signal)),
  );
}

function detect(value) {
  if (signalIdentity(value)) return "aes";
  if (isLegacyEnvelope(value)) return "legacy";
  return "";
}

const plainSignal = { code: "0", signal: [{ using: true, cpeno: 1 }] };
const legacyProbe = { data: "+2j4zUClduWNHc2LNm8p6w==" };
const aesProbe = { code: "0", signal: [{ mac: "001122334455" }] };

if (detect(plainSignal) !== "") {
  throw new Error("plain signal without mac/id must not be accepted");
}
if (detect(legacyProbe) !== "legacy") {
  throw new Error("DES data envelope must select the legacy protocol");
}
if (detect(aesProbe) !== "aes") {
  throw new Error("signal mac/id must select the AES protocol");
}

process.stdout.write("PASS: APP 2.3.1 protocol selection model\n");
