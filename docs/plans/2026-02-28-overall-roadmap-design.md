# Twinbox Overall Roadmap (Maart - Augustus 2026)

## 1. Productvisie

Twinbox levert een "one-command private cloud platform":
- gebruiker start op Proxmox met 1 wizard-flow;
- Twinbox bouwt een volledig beheerd Kubernetes-platform;
- platform levert standaard networking, storage, backups, security en app-automatisering;
- dagelijkse operatie blijft beheersbaar met minimaal personeel.

## 2. Strategische doelgroepvolgorde

1. **Fase 1: Homelab + technical SMB adopters**
- doel: snelle feedback op UX, installatie, betrouwbaarheid;
- succes: installatie in < 45 minuten, herstel bij fouten zonder handwerk.

2. **Fase 2: SMB (hoofdsegment)**
- doel: stabiele day-2 operatie (updates, backups, identity, alerts);
- succes: 80% van beheeracties via Twinbox UI/API, geen shell-niveau nodig.

3. **Fase 3: Enterprise pilots**
- doel: controle, governance en integratie (RBAC, audit, policy);
- succes: security/reviewteams kunnen platform goedkeuren zonder maatwerkfork.

## 3. Architectuurkoers

- **Control plane nu:** Management VM met Docker Compose (snel itereren, reproduceerbaar).
- **Control plane later:** services met striktere contracten, daarna geleidelijke Kubernetes-native componenten waar dat waarde geeft.
- **Execution model:** declaratief en idempotent (desired state), niet scriptketens zonder state.
- **Golden path eerst:** 1 referentiepad dat altijd werkt, daarna uitbreiden met varianten.

## 4. Kwaliteitsprincipes (niet onderhandelbaar)

- **Idempotent provisioning:** elke run veilig herhaalbaar.
- **Veilige defaults:** least privilege, secrets uit files/keystores, geen plaintext in logs.
- **Observeerbaarheid:** elke stap traceerbaar met status, events en hersteladvies.
- **Testpiramide:** unit + contract + integratie + e2e op echte Proxmox/Talos testmatrix.
- **Onderhoudbaarheid:** kleine services, expliciete API-contracten, ADR's bij architectuurbesluiten.
- **Upgradebaarheid:** semver, migratiescripts, rollback per release.

## 5. Roadmap per maand

## Maart 2026 - Fundament en betrouwbaarheid

Doelen:
- wizard en manager-runtime harden voor consistente bootstrap;
- state-model standaardiseren (clusters/jobs/logs/events);
- foutscenario's expliciet maken (timeouts, partial failures, retries).

Deliverables:
- declaratief cluster-spec schema (versiebeheer);
- job-orchestratie met duidelijke lifecycle en retry policy;
- troubleshooting-flow in UI met actionable foutcodes.

Quality gate:
- e2e green op verse Proxmox node;
- bootstrap + her-run zonder handmatige cleanup.

## April 2026 - Security baseline + identity basis

Doelen:
- authn/authz van "LAN-only" naar echte identity-baseline;
- secrets lifecycle veilig maken.

Deliverables:
- ingebouwde login (eerste IDP-integratiepad + lokale fallback);
- RBAC basisrollen (owner/operator/viewer);
- secret management-policy (opslag, rotatie, redaction in logs).

Quality gate:
- security checklist verplicht per release;
- audit trail voor kritieke acties (cluster create/bootstrap/delete).

## Mei 2026 - Storage + backup/restore v1

Doelen:
- data durability als kernfeature;
- herstelbaar platform aantonen.

Deliverables:
- standaard storage class flow (config + health);
- geautomatiseerde backups (schema, retentie, restore wizard);
- restore-validatie als eerste klas workflow.

Quality gate:
- maandelijkse disaster rehearsal: restore naar schone omgeving slaagt;
- RPO/RTO-targets gedefinieerd en gemeten.

## Juni 2026 - Netwerk, tunnels en operationele UX

Doelen:
- veilige externe toegang zonder handmatige netwerk-puzzel;
- operationele complexiteit minimaliseren.

Deliverables:
- tunnel/ingress wizard met veilige defaults;
- certificaatbeheer en rotatie-flow;
- centrale statuspagina (cluster, backup, updates, security warnings).

Quality gate:
- nieuwe gebruiker kan app extern publishen zonder shell-commandos;
- alle operationele stappen zichtbaar in UI events.

## Juli 2026 - App platform + updates v1

Doelen:
- "cloud apps met 1 klik" betrouwbaar maken;
- updatebeleid voorspelbaar en veilig.

Deliverables:
- curated app catalog (start klein: 3-5 bewezen apps);
- standaard app templates met idp, permissions, storage en backup hooks;
- update channels (stable/canary) + rollback knop.

Quality gate:
- app install/update/rollback e2e bewezen;
- geen breaking updates zonder migratiepad.

## Augustus 2026 - SMB product readiness

Doelen:
- klaar voor eerste betalende SMB pilots;
- supportability en maintainability aantoonbaar.

Deliverables:
- release policy + support matrix;
- ingebouwde diagnostics bundle;
- onboarding docs + runbooks voor operators.

Quality gate:
- 2-3 pilotklanten succesvol live;
- kritieke issues binnen afgesproken SLA oplosbaar.

## 6. Enterprise pad (na augustus, parallel voorbereiden)

Voorbereiden, maar pas zwaar investeren na SMB-fit:
- SSO/SCIM varianten;
- policy-as-code en compliance exports;
- multi-cluster fleet beheer;
- hardening guides en formele change control.

## 7. Engineering operating model

- **Release cadence:** 2-wekelijkse release train.
- **Werkvorm:** trunk-based, kleine PR's, feature flags.
- **Kwaliteitspoorten per PR:** tests, security checks, contract checks, docs update verplicht.
- **Architectuurdiscipline:** ADR bij elk niet-triviaal besluit.
- **Definition of Done:** code + tests + observability + docs + rollback plan.

## 8. KPI's voor de komende 6 maanden

- Time-to-first-cluster (TTFC) < 45 min.
- Bootstrap success rate > 95% op ondersteunde matrix.
- Mean time to recover (MTTR) bij failed job < 30 min.
- Restore success rate > 99% in rehearsal.
- Upgrade success rate > 98% zonder handmatige interventie.

## 9. Grote risico's en mitigaties

1. **Scope-overload (alles tegelijk willen)**
- mitigatie: strikte fasegates, max 1 nieuw platformdomein per maand.

2. **Script-spaghetti in orchestration**
- mitigatie: desired-state model + contract tests + expliciete state machine.

3. **Security debt door snelle groei**
- mitigatie: security gate verplicht vanaf april, niet pas bij enterprise.

4. **Operatie te complex voor klein team**
- mitigatie: self-diagnostics, runbooks, productized recovery flows.

## 10. Besluit

Ja, je gaat in de juiste richting, mits je de "one command" UX combineert met harde platformdiscipline: declaratief, testbaar, observeerbaar en herstelbaar. De beste route is homelab/smb eerst winnen op betrouwbaarheid en beheergemak, en enterprise capabilities gefaseerd toevoegen zonder de core eenvoud op te offeren.
