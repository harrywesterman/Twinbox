import fs from "fs";
import { spawnSync } from "child_process";

function readRequiredFile(file, label) {
  if (!file || !fs.existsSync(file)) {
    throw new Error(`${label} file not found: ${file || "(empty)"}`);
  }
  const value = fs.readFileSync(file, "utf8").trim();
  if (!value) {
    throw new Error(`${label} file is empty: ${file}`);
  }
  return value;
}

function ensureAppDataDir(runtimeEnv) {
  const appDataDir = runtimeEnv.BITWARDENCLI_APPDATA_DIR || "/opt/twinbox/bootstrap/bw-runtime";
  fs.mkdirSync(appDataDir, { recursive: true, mode: 0o700 });
  return appDataDir;
}

function normalizeServerUrl(value) {
  return String(value || "").trim().replace(/\/+$/, "");
}

function buildRuntimeEnv(runtimeEnv, extraEnv = {}) {
  return {
    ...process.env,
    ...runtimeEnv,
    ...extraEnv,
    BITWARDENCLI_APPDATA_DIR: ensureAppDataDir(runtimeEnv),
  };
}

function summarizeFailure(result, args) {
  const stderr = String(result.stderr || "").trim();
  const stdout = String(result.stdout || "").trim();
  return stderr || stdout || `bw ${args.join(" ")} exited with code ${result.status}`;
}

export function runBitwardenCommand(runtimeEnv, args, { allowFailure = false, extraEnv = {}, input } = {}) {
  const result = spawnSync("bw", args, {
    encoding: "utf8",
    env: buildRuntimeEnv(runtimeEnv, extraEnv),
    input,
    maxBuffer: 10 * 1024 * 1024,
  });

  if (result.error?.code === "ENOENT") {
    throw new Error("bw is required for Vaultwarden secret resolution");
  }
  if (result.error) {
    throw result.error;
  }
  if (!allowFailure && result.status !== 0) {
    throw new Error(summarizeFailure(result, args));
  }

  return result;
}

export function configureBitwardenServer(runtimeEnv, serverUrl) {
  runBitwardenCommand(runtimeEnv, ["config", "server", serverUrl]);
}

export function logoutBitwarden(runtimeEnv) {
  runBitwardenCommand(runtimeEnv, ["logout"], { allowFailure: true });
}

export function readBitwardenStatus(runtimeEnv) {
  const result = runBitwardenCommand(runtimeEnv, ["status"], { allowFailure: true });
  if (result.status !== 0) {
    throw new Error(summarizeFailure(result, ["status"]));
  }
  return JSON.parse(result.stdout || "{}");
}

export function ensureBitwardenLogin(runtimeEnv, serverUrl) {
  configureBitwardenServer(runtimeEnv, serverUrl);

  const status = readBitwardenStatus(runtimeEnv);
  if (status?.status === "unlocked" || status?.status === "locked") {
    return status;
  }
  if (status?.status && status.status !== "unauthenticated") {
    logoutBitwarden(runtimeEnv);
    configureBitwardenServer(runtimeEnv, serverUrl);
  }

  const clientId = readRequiredFile(runtimeEnv.VAULTWARDEN_CLIENTID_FILE, "Vaultwarden client id");
  const clientSecret = readRequiredFile(runtimeEnv.VAULTWARDEN_CLIENTSECRET_FILE, "Vaultwarden client secret");

  runBitwardenCommand(runtimeEnv, ["login", "--apikey"], {
    extraEnv: {
      BW_CLIENTID: clientId,
      BW_CLIENTSECRET: clientSecret,
    },
  });

  return readBitwardenStatus(runtimeEnv);
}

export function unlockBitwarden(runtimeEnv, { serverUrl } = {}) {
  const passwordFile = runtimeEnv.VAULTWARDEN_PASSWORD_FILE;
  if (!passwordFile || !fs.existsSync(passwordFile)) {
    throw new Error(`Vaultwarden password file not found: ${passwordFile || "(empty)"}`);
  }

  let result = runBitwardenCommand(runtimeEnv, ["unlock", "--passwordfile", passwordFile, "--raw"], {
    allowFailure: true,
  });
  if (result.status !== 0 && String(result.stderr || result.stdout || "").includes("Invalid master password")) {
    logoutBitwarden(runtimeEnv);
    if (serverUrl) {
      ensureBitwardenLogin(runtimeEnv, serverUrl);
    }
    result = runBitwardenCommand(runtimeEnv, ["unlock", "--passwordfile", passwordFile, "--raw"]);
  } else if (result.status !== 0) {
    throw new Error(summarizeFailure(result, ["unlock", "--passwordfile", passwordFile, "--raw"]));
  }

  const session = String(result.stdout || "").trim();
  if (!session) {
    throw new Error("bw unlock returned an empty session");
  }
  return session;
}

export function syncBitwarden(runtimeEnv, session) {
  runBitwardenCommand(runtimeEnv, ["sync", "--session", session]);
}

export function listBitwardenItems(runtimeEnv, search, session) {
  const result = runBitwardenCommand(runtimeEnv, ["list", "items", "--search", search, "--session", session]);
  return JSON.parse(result.stdout || "[]");
}

export function getBitwardenItem(runtimeEnv, itemId, session) {
  const result = runBitwardenCommand(runtimeEnv, ["get", "item", itemId, "--session", session]);
  return JSON.parse(result.stdout || "{}");
}

export function getBitwardenItemTemplate(runtimeEnv, session) {
  const result = runBitwardenCommand(runtimeEnv, ["get", "template", "item", "--session", session]);
  return JSON.parse(result.stdout || "{}");
}

export function createBitwardenItem(runtimeEnv, itemJson, session) {
  const encoded = runBitwardenCommand(runtimeEnv, ["encode"], {
    input: JSON.stringify(itemJson),
  }).stdout;
  const result = runBitwardenCommand(runtimeEnv, ["create", "item", "--session", session], {
    input: encoded,
  });
  return JSON.parse(result.stdout || "{}");
}

export function editBitwardenItem(runtimeEnv, itemId, itemJson, session) {
  const encoded = runBitwardenCommand(runtimeEnv, ["encode"], {
    input: JSON.stringify(itemJson),
  }).stdout;
  const result = runBitwardenCommand(runtimeEnv, ["edit", "item", itemId, "--session", session], {
    input: encoded,
  });
  return JSON.parse(result.stdout || "{}");
}

export function downloadBitwardenAttachment(runtimeEnv, attachmentName, itemId, outputFile, session) {
  runBitwardenCommand(runtimeEnv, [
    "get",
    "attachment",
    attachmentName,
    "--itemid",
    itemId,
    "--output",
    outputFile,
    "--session",
    session,
  ]);
}

export function createBitwardenAttachment(runtimeEnv, filePath, itemId, session) {
  runBitwardenCommand(runtimeEnv, [
    "create",
    "attachment",
    "--file",
    filePath,
    "--itemid",
    itemId,
    "--session",
    session,
  ]);
}

export function deleteBitwardenAttachment(runtimeEnv, attachmentId, session) {
  runBitwardenCommand(runtimeEnv, ["delete", "attachment", attachmentId, "--session", session, "--permanent"]);
}
