import fs from "fs";
import YAML from "yaml";

import { loadCatalogDefinitions as loadSharedCatalogDefinitions } from "../../../lib/catalog-definitions.mjs";

function loadYaml(file) {
  return YAML.parse(fs.readFileSync(file, "utf8"));
}

export function loadCatalogDefinitions(options = {}) {
  return loadSharedCatalogDefinitions({
    ...options,
    loadYamlFn: options.loadYamlFn || loadYaml,
  });
}
