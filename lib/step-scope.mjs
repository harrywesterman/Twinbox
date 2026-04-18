export function isClusterScopedStep(step) {
  return step?.category_id === "talos-cluster" || step?.category_id === "apps";
}
