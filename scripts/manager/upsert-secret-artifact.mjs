#!/usr/bin/env node

import fs from "fs";
import path from "path";

import { createSecretBroker } from "../../lib/secrets/broker.mjs";

function usage() {
  process.stderr.write(
    "Usage: upsert-secret-artifact.mjs --scope <scope> --item <item> --attachment <name> --source <path> [--cluster-id <id>]\n"
  );
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const parsed = {
    scope: "cluster",
    clusterId: "",
    item: "",
    attachment: "",
    source: "",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    const next = argv[index + 1];

    switch (current) {
      case "--scope":
        parsed.scope = String(next || "").trim();
        index += 1;
        break;
      case "--cluster-id":
        parsed.clusterId = String(next || "").trim();
        index += 1;
        break;
      case "--item":
        parsed.item = String(next || "").trim();
        index += 1;
        break;
      case "--attachment":
        parsed.attachment = String(next || "").trim();
        index += 1;
        break;
      case "--source":
        parsed.source = String(next || "").trim();
        index += 1;
        break;
      case "-h":
      case "--help":
        usage();
        process.exit(0);
        break;
      default:
        fail(`Unknown argument: ${current}`);
    }
  }

  if (!parsed.scope) {
    fail("scope is required");
  }
  if (!parsed.item) {
    fail("item is required");
  }
  if (!parsed.attachment) {
    fail("attachment is required");
  }
  if (!parsed.source) {
    fail("source is required");
  }
  if (parsed.scope === "cluster" && !parsed.clusterId) {
    fail("cluster-id is required for cluster-scoped secrets");
  }
  if (!fs.existsSync(parsed.source)) {
    fail(`source file not found: ${parsed.source}`);
  }

  return parsed;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const broker = createSecretBroker(process.env);

  broker.upsertAttachment(
    {
      scope: args.scope,
      item: args.item,
      cluster_id: args.clusterId || undefined,
      attachment: args.attachment,
      format: "file",
    },
    path.resolve(args.source),
    {
      clusterId: args.clusterId || undefined,
    }
  );
}

main();
