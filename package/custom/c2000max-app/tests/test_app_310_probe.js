"use strict";

// Protocol selection and AES primitives recovered from 鲲鹏无限 3.1.0.
const crypto = require("crypto");

const SERVER_SECRET =
  "59ad910d5902374f90224e063538b100535c46340684daf5efeefc16afc4543" +
  "cbf2a62c2dddc40f7d03a3d995d9c54ef7727754e3ec6b319807291e63f1806fbe" +
  "25f9b00ac82f8306971dbd58546dc759a465bad72d77b87f03598c2b6b0c6042e6e" +
  "96b68e65fde16b07be81971461d76d2658c00effbdbd2bd6af123a6a1a0f";
const AES_KEY = SERVER_SECRET.slice(0, 32);
const AES_IV = Buffer.from("000102030405060708090a0b0c0d0e0f", "hex");

function signalIdentity(value) {
  const list = value && Array.isArray(value.signal)
    ? value.signal
    : value && value.result && Array.isArray(value.result.signal)
      ? value.result.signal
      : [];
  const first = list[0];
  if (!first || typeof first !== "object") return "";
  return String(first.mac || first.id || "").trim();
}

function detect(value) {
  if (signalIdentity(value)) return "aes";
  if (value && typeof value.data === "string") return "legacy";
  return "";
}

function sortedTokenSource(value) {
  return Object.keys(value)
    .filter((key) => key !== "token" && value[key] != null)
    .sort()
    .map((key) => key + value[key])
    .join("");
}

const modernProbe = {
  code: "0",
  signal: [{ mac: "FC83C616B976", id: "FC83C616B976" }],
};
if (detect(modernProbe) !== "aes") {
  throw new Error("3.1.0 must select AES from signal[0].mac/id");
}

function plainSignalRoute(hasValidSession) {
  return hasValidSession ? "real-signal" : "capability-probe";
}
if (plainSignalRoute(false) !== "capability-probe") {
  throw new Error("unauthenticated plaintext signal must remain a probe");
}
if (plainSignalRoute(true) !== "real-signal") {
  throw new Error("password-auth plaintext signal must return modem data");
}
if (AES_KEY !== "59ad910d5902374f90224e063538b100") {
  throw new Error("3.1.0 AES fallback key mismatch");
}

const auth = {
  device_code: "PHONE-1",
  timestamp: "2026-08-28 12:34:56",
  trans_id: "310",
};
const source = sortedTokenSource(auth);
if (source !==
    "device_codePHONE-1timestamp2026-08-28 12:34:56trans_id310") {
  throw new Error("3.1.0 sorted token source mismatch");
}
const token = crypto.createHash("md5")
  .update(source + AES_KEY)
  .digest("hex");
if (token !== "081e21c7a8824c0130f144c4c3116001") {
  throw new Error("3.1.0 auth token vector mismatch");
}

const plain = JSON.stringify(Object.assign({}, auth, { token }));
const cipher = crypto.createCipheriv(
  "aes-256-cbc",
  Buffer.from(AES_KEY, "utf8"),
  AES_IV,
);
const encrypted = Buffer.concat([
  cipher.update(Buffer.from(plain, "utf8")),
  cipher.final(),
]).toString("base64");
const decipher = crypto.createDecipheriv(
  "aes-256-cbc",
  Buffer.from(AES_KEY, "utf8"),
  AES_IV,
);
const decrypted = Buffer.concat([
  decipher.update(Buffer.from(encrypted, "base64")),
  decipher.final(),
]).toString("utf8");
if (decrypted !== plain) {
  throw new Error("3.1.0 AES-256-CBC round trip failed");
}

process.stdout.write("PASS: APP 3.1.0 AES protocol model\n");
