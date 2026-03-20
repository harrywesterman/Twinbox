# Network Defaults And IP Suggestions Design

**Problem:** The guided Talos provisioning step currently seeds fields with defaults that can come from container-local networking rather than the operator's real LAN. It can also suggest a `start_ip` whose following addresses are not all free, which breaks the expectation of a contiguous block for control plane and worker nodes.

**Decision:** Keep the provisioning form auto-filled from the manager API, but make that API return only sane host-network defaults and only contiguous free node ranges. Users can still override any field after the defaults are applied.

## Why This Approach

- The API already centralizes subnet probing and host-network detection, so fixing it there avoids duplicating fragile heuristics in the UI.
- Filtering loopback and container-resolver entries from DNS detection prevents obviously wrong defaults like `127.0.0.11`.
- Requiring a fully free contiguous block for the suggested node range matches how Talos nodes are provisioned and avoids unusable start-IP recommendations.

## Behavior Changes

- `node_prefix_length` stays derived from the host management interface.
- `gateway_ip` stays derived from the host default route, with the same subnet-based fallback when no route is detected.
- `dns_servers` are read from `resolv.conf`, but loopback and duplicate addresses are ignored; if nothing usable remains, the fallback is `1.1.1.1`.
- `dns_domain` prefers a real search/domain value and otherwise falls back to an empty string instead of `localdomain`-style placeholders.
- `start_ip` suggestions advance until the full node block is available, not just the first address.

## Expected Outcome

- A management IP on `192.168.2.0/24` yields `24`, `192.168.2.1`, and `1.1.1.1`-style defaults rather than container-network values.
- A blocked `.58` means a suggested `start_ip` of `.57` is rejected in favor of the next fully free run.
- Manual edits in the form continue to win over later refreshes of the suggestion payload.
