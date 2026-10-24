# Twinbox beveiligingsoverzicht — uitvoerplan

Datum: 24 oktober 2026. Dit document is de uitvoeropdracht voor een volgend model.

## Doel en vaststaande keuzes

Bouw een beveiligingsoverzicht voor niet-technische beheerders in de Twinbox Portal,
met een beknopte installatiecontrole in de Management UI. Toon risico's, acties,
bewijs en ontbrekende controles. Een CVE-lijst is alleen een detailweergave.

Er bestaat momenteel geen cluster en ook geen Management VM. Gebruik fixtures voor
ontwikkeling; claim geen live verificatie. Gepubliceerde images bestaan wel.

Werk op `main`. Lees de actuele AGENTS.md. Laat bestaande wijzigingen staan.
Voer de fasen hieronder op volgorde uit. Dit plan geeft geen opdracht om tijdens
de uitvoering nieuwe infrastructuur aan te maken of automatisch te deployen.

## 1. Bestaande aansluitpunten

Controleer deze bestanden vóór wijzigingen; regelnummers en details kunnen veranderen:

- `scripts/ci/image_matrix.py`: gedeelde inventaris van zeven eigen images.
- `.github/workflows/image-vulnerability-monitor.yml`: dagelijkse/manuele Trivy-scans,
  `report.json` en `digest.txt` als artifacts, momenteel 14 dagen bewaard.
- `scripts/ci/published_image_issue.py`: maakt de samenvattende security-issue;
  laat momenteel onder andere Target, distro en leveranciersstatus weg en kapt af.
- `tests/test_image_security_policy.py`: bestaande scan- en issue-contracten.
- `portal/server.mjs`: `requireAdminSession`, `requestManagerJson` en bestaande
  `/api/admin/observability`- en `/api/admin/updates`-patronen.
- `portal/src/user-admin-model.js`: beheerdersnavigatie.
- `portal/src/App.jsx`, `portal/src/App.css`: bestaande routes en schermen.
- `manager-api/src/server.js`, `manager-api/src/lib/`: API en persistente JSON-state.
- `manager-web/src/App.jsx`: Management UI en installatieflow.

Let op: de logische image `twinbox-jitsi-openid` gebruikt bewust het GHCR-pakket
`twinbox-manager-worker` met tag `jitsi-openid-latest`. Dit is geen rapportagefout.
Neem mappings over uit de inventaris; leid de componentnaam niet af uit de registrynaam.

## 2. Productgedrag en grenzen

De Portal krijgt `/admin/security`, alleen toegankelijk voor beheerders.
De Management UI toont hetzelfde oordeel over de te installeren eigen images,
ook wanneer nog geen cluster bestaat.

Het overzicht bevat vijf onderwerpen:

| Onderwerp | Eerste versie |
| --- | --- |
| Software en updates | Echte scanresultaten en geautomatiseerde beoordeling van eigen images |
| Bereikbaarheid | Onbekend totdat actuele deployment-/netwerkmetingen zijn aangesloten |
| Accounts en toegang | Onbekend totdat een echte controle is aangesloten |
| Detectie | Onbekend totdat werkende bewaking aantoonbaar gecontroleerd is |
| Back-ups en herstel | Onbekend totdat bewijs van een hersteltest is aangesloten |

Lever versie 1 volledig werkend voor softwareveiligheid. De andere onderwerpen
krijgen eerlijke uitleg over ontbrekend bewijs, geen verzonnen aantallen of groene
vinkjes. Implementatie van hun collectors is expliciet vervolgwerk.

Versie 1 bestrijkt alleen de zeven eigen images. Andere images, hosts, Talos en
netwerkapparatuur tellen zichtbaar als buiten de meetdekking. Geen claim dat alle
Twinbox-componenten zijn gecontroleerd. Voeg geen automatische pentest toe.

Geen veiligheidscijfer zoals 92/100 en geen algemene claim 'veilig'. Een groen
onderdeel betekent uitsluitend dat de beschreven actuele controles geen open
bevindingen opleveren. Het globale overzicht blijft onvolledig bij ontbrekende
onderwerpen, ook als de images schoon zijn.

## 3. Fase A — volledig, herleidbaar scanrapport

Voeg `scripts/ci/security_report.py` en gerichte Python-tests toe.

1. Lees alle zeven volledige scanartifacts via de gedeelde inventaris.
2. Scan het vastgelegde immutable digest, niet opnieuw de veranderlijke tag.
   Bij multi-platform images vermeld je het gescande platform; claim geen dekking
   van andere platformen. Neem platform/manifest-identiteit op in de rapportage.
3. Bewaar alle severities. Verwijder de HIGH/CRITICAL-beperking uit de dagelijkse
   gegevensverzameling; bestaande blokkeringsregels in Verify/Publish blijven
   fixbare Critical totdat hun beleid apart wordt gewijzigd.
4. Geef iedere bevinding een stabiele sleutel gebaseerd op logische image,
   digest, platform, Target, pakketidentiteit, geïnstalleerde versie en CVE.
   Eén CVE in verschillende binaries blijft onderscheidbaar. Tel unieke CVE's
   en getroffen componenten afzonderlijk; tel niet elk duplicaat als een nieuw lek.
5. Schrijf een versieerbaar `security-report.json` met minimaal:

```text
schemaVersion, repository, workflowRunId, commitSha, generatedAt,
scannerVersion, databaseUpdatedAt, coverage,
images[{logicalName, publishedRef, digest, platform, distro, scanStatus,
        scannedAt, findings[]}], sourceErrors[]

finding: id, vulnerabilityId, packageName, packageIdentity,
         installedVersion, fixedVersions, target, packageType,
         originalSeverity, vendorStatus, advisoryUrls,
         assessmentStatus, assessmentReason, evidenceRefs, ruleId
```

Ontbrekende scanner-/DB-metadata is `null` met uitleg; verzin geen datum.
JSON-parse-, registry- en scannerfouten moeten de workflow laten falen. Een scan
zonder Results is niet vanzelf succesvol: valideer scanmetadata en rapporteer
ontbrekende inventaris afzonderlijk. Een geldige scan zonder kwetsbaarheden mag wel.

6. Voeg een aggregatiejob toe na alle scans, met artifactnaam
   `twinbox-security-report`. Publiceer alleen een complete set als complete scan.
   Houd bestaande losse artifacts beschikbaar voor onderzoek.
7. Laat de bestaande issue hetzelfde volledige gegevensmodel gebruiken, maar houd
   de tekst kort. Vermeld beoordeeld, open en nog te onderzoeken apart. Een
   tekstlimiet mag nooit de onderliggende aantallen/gegevens veranderen.
   Behoud deduplicatie en sluit de issue niet bij een mislukte/onvolledige scan.

## 4. Fase B — reproduceerbare beoordeling

Voeg `config/security/assessment-rules.json` en een JSON-schema toe.
Implementeer beoordeling in Python naast de rapportgenerator; voer deze logica
niet nogmaals anders uit in de frontend.

Gebruik deze statussen:

- `needs_review`: onvoldoende bewijs; standaard voor nieuwe bevindingen.
- `affected`: betrouwbare bron bevestigt dat het aangetroffen onderdeel getroffen is.
- `not_affected`: voldoende, exact toepasselijk bewijs dat dit onderdeel niet geraakt wordt.
- `resolved`: alleen na een geslaagde nieuwe scan van dezelfde artifact zonder
  die bevinding, of een gescande vervangende artifact; oude artifacts blijven
  historisch getroffen. Verandering van tag is geen bewijs van herstel.

Bewaar actie-informatie apart: `update_available`, `awaiting_upstream`,
`investigate`, `no_action_required`. Geen fix betekent niet minder risico.
Internetbereikbaarheid, bekende actieve uitbuiting en privileges verhogen prioriteit;
ontbrekende exposuregegevens maken een bevinding niet `not_affected`.

Voor versie 1 is automatische beoordeling gebaseerd op versiebeheerbare regels
met betrouwbare adviesbronnen. Geen vrije AI-classificatie en geen automatisch
binnenhalen/vertrouwen van willekeurige VEX-documenten. VEX-import is vervolgwerk.
De datastructuur moet bewijs en scope wel kunnen bewaren.

Elke regel heeft: id, CVE, exacte package/distro/release/version-scope, targets
indien relevant, oordeel, bron-URL, rationale, reviewedAt en expiresAt.
Verlopen, conflicterende, ongeldige of niet exact passende regels leveren
`needs_review` met uitleg op. Geen algemene ignore op alleen CVE-id.
Gebruik distrogeschikte versievergelijking, of beperk een eerste regel tot de
exact geverifieerde versie; vergelijk Debian-versies nooit lexicografisch.
Een bron die verdwijnt/verandert moet bij herbeoordeling tot review leiden;
sla de beoordeelde passage/hash op. Bronverversing kan los van de dagelijkse scan
worden uitgevoerd; verlopen bewijs mag intussen nooit geldig blijven.

Eerste concrete regel, na verificatie door uitvoerder:
`CVE-2023-45853`, Debian Bookworm, `zlib1g`, exact
`1:1.2.13.dfsg-1`: Debian vermeldt dat de getroffen contrib/minizip-code niet
wordt meegebouwd. Bron:
https://security-tracker.debian.org/tracker/CVE-2023-45853

Pas dit oordeel NIET toe op `minizip`, `pyminizip`, andere distributies of onbekende
versies. Het scannerlabel Critical blijft zichtbaar als oorspronkelijke severity.
Voor Go/kubectl-meldingen blijft het oordeel review nodig zolang alleen
versiematching beschikbaar is. Een actuele versie is geen vrijwaring.

AI kan later teksten uitleggen, uitsluitend op basis van opgeslagen bewijs.
AI mag nooit zelfstandig bevindingen sluiten, risico's accepteren of scans groen maken.

## 5. Fase C — veilige gegevensaanvoer en backend

Voeg `manager-api/src/lib/security-report.js`, `security-overview.js` en tests toe.

Gebruik GitHub Actions artifacts als eerste transport; parse nooit de issue-body
als API. Repo en workflow staan vast op deze repository en
`image-vulnerability-monitor.yml`. Selecteer runs op main, controleer repository,
workflow-identiteit, branch, run attempt en commit. Geen artifacts uit PR-runs.

Gebruik alleen backend-side een optionele `TWINBOX_SECURITY_GITHUB_TOKEN` met
read-only Actions-toegang tot deze repository. Werk env-documentatie en de
bestaande secret/config-injectie bij; geen credentials in UI, fixtures of logs.
Geen publish-token hergebruiken. Zonder toegang: expliciet 'bron niet beschikbaar'.
Tokenprovisioning door een beheerder kan na installatie nodig blijven en moet
als configuratiestatus zichtbaar zijn; claim zonder token geen werkende verbinding.

Download het rapport van de laatste complete succesvolle run, en controleer
ook de status van de nieuwste poging. Een latere mislukte run moet zichtbaar zijn,
ook als eerder bruikbare resultaten beschikbaar zijn.
Valideer schema, grootte (maximaal 10 MiB uitgepakt), timestamps en artifactnaam.
Extract alleen het verwachte JSON-bestand; voorkom ZIP path traversal/ZIP-bombs.
Gebruik vaste GitHub API-/artifactdownloadroutes; volg uitsluitend HTTPS-redirects
naar de door GitHub gebruikte artifactopslag zonder Authorization door te sturen
naar een andere host. Geen door gebruikers aangeleverde fetch-URL's.

Cache 15 minuten; ververs ook server-side op eerste request na de TTL.
Bewaar de laatste geldige snapshot atomair onder de bestaande dataRoot in
`security/`, niet in de checkout. Bij timeout (10 seconden), rate limit of fout:
toon cached resultaten met bronfout; wis de vorige snapshot niet.
Een rapport ouder dan 36 uur is verouderd. Ook artifactverval, ontbrekende images,
ongeldige schemas en toekomstige timestamps moeten zichtbaar falen.

API-contract:

- `GET /api/security/overview?scope=published`: samenvatting voor installatie.
- `GET /api/security/images/:imageKey`: detail, alleen inventaris-keys accepteren.
- `GET /api/security/overview?scope=runtime`: versie 1 geeft expliciet
  `not_measured`, tenzij echte runtime-inventaris beschikbaar is.
- Portal: `GET /api/admin/security` en `/api/admin/security/images/:imageKey`,
  via bestaande manager-proxy en `requireAdminSession`.

Respecteer bestaande Manager API-netwerktoegangscontrole. De Portal mag de
beheerdercontrole niet alleen client-side uitvoeren. Geen downloadproxy voor
willekeurige URL's en geen token of rauwe foutresponse teruggeven.

Dataflow: CI-scan → beoordeeld JSON-artifact → Manager API cache → Portal/admin UI.
De Management UI gebruikt rechtstreeks dezelfde Manager API en hetzelfde model.

## 6. Fase D — overzicht en details

Voeg `portal/src/admin-security-model.js`, `AdminSecurityPage.jsx` en tests toe.
Sluit aan op bestaande componenten/styling, zonder App.jsx verder vol te schrijven.
Voeg 'Beveiliging' toe aan de beheerdersnavigatie in `user-admin-model.js`.

Bovenaan:

- Duidelijke tekststatus: `Actie nodig`, `Beoordeling nodig`,
  `Geen open bevindingen binnen de gecontroleerde scope`, of `Onvoldoende gegevens`.
- Bij gemengde toestand: toon zowel urgente acties als onvolledige dekking.
- Gepubliceerde images versus draaiende installatie; runtime niet gemeten betekent
  nooit dat de gepubliceerde versies daadwerkelijk draaien.
- Laatste succesvolle controle, laatste mislukte poging, gescande platforms,
  aantal gecontroleerde/verwachte eigen images, ontbrekende onderwerpen.
- Eerst concrete acties in gewone taal, met doel, reden en verwachte oplossing.

Onderwerpen zijn aanklikbaar. Softwaredetail toont de getroffen services/binaries;
pas daarna pakketnamen en CVE's. Toon per bevinding bron, originele severity,
oordeel, motivatie, fixbeschikbaarheid, artifact-digest, scantijd en bewijsdatum.
Ook `not_affected` blijft vindbaar via een filter, met aantallen en bewijs.

Andere onderwerpen leggen uit welke controle ontbreekt en dat er nog geen
conclusie is. Geen percentage 'veilig' en geen nepknop die een pentest suggereert.
Gebruik tekst/iconen naast kleur; volledige toetsenbordbediening en mobiele layout.

Geen runtime aanwezig: toon dit uit daadwerkelijke state. Kan state niet worden
opgehaald, toon 'onbekend', niet 'geen installatie'. Op deze machine bestaat geen
installatie; een ontwikkelfixture mag dat simuleren maar wordt nooit productie-default.

Voeg `manager-web/src/SecurityPreflight.jsx` en bijbehorende model/tests toe.
Toon vóór de bestaande cluster-aanmaakactie een beknopte kaart met dezelfde
gepubliceerde-imagebevindingen en datakwaliteit, inclusief doorklikdetails.
Maak deze eerste kaart adviserend: wijzig bestaande installatie-/CI-blokkering
niet stilzwijgend. Nieuwe blokkeringsregels vereisen een afzonderlijke beleidskeuze.

## 7. Verplichte tests en acceptatie

Schrijf per fase tests samen met de code. Gebruik kleine, ontsmette fixtures.

- Alle zeven inventaris-items verschijnen; Jitsi's afwijkende registrymapping klopt.
- Scan gebruikt exact het digest dat het rapport vermeldt; tagmutatie verandert dat niet.
- Een pakket-CVE in twee binaries blijft herleidbaar; tellingen leggen duplicaten uit.
- Alle severities blijven beschikbaar, ook wanneer de hoofdweergave prioriteert.
- Debian-zlib-regel past alleen op de gedocumenteerde scope; minizip en pyminizip
  blijven open. Verlopen/conflicterend bewijs levert review op.
- Geen fix, `will_not_fix`, geen bekende exploit of interne exposure sluit niets automatisch.
- Geen scan, ontbrekende image, verkeerde branch/run, kapotte JSON, bronfout,
  verkeerde platformdekking, toekomstige/verouderde datum: nooit groen.
- Nieuwste scan faalt: vorige resultaten blijven zichtbaar, met de fout erbij.
- Schone gepubliceerde images maken runtime en andere onderwerpen niet groen.
- Een nieuwe artifact zonder bevinding sluit een oude artifact niet historisch vrij.
- Niet-ingelogd en niet-admin krijgen geen Portal securitygegevens.
- Backend-token blijft server-side; kwaadaardige URL's/ZIP-paden worden geweigerd.
- Portal en installatiekaart vertellen voor dezelfde snapshot hetzelfde verhaal.
- Bestaande issue-deduplicatie, onvolledige-scanbehandeling en Critical-gate blijven werken.

Voer minimaal uit:

```bash
python3 -m pytest -q tests
node --test manager-*/test/*.mjs
node --test portal/test/*.mjs
make lint
make format-check
npm run build --prefix portal
npm run build --prefix manager-web
```

Controleer gewijzigde JS/Python/shell/Compose aanvullend volgens AGENTS.md.
Doe browserverificatie via de beschikbare browsertools voor minstens: lege state,
actie nodig, beoordeling nodig, verouderde gegevens en detailnavigatie.
Als browserverificatie of dependencies ontbreken, meld precies wat niet geverifieerd is.
Geen screenshots of fixtures presenteren als bewijs van een live cluster.

## 8. Documentatie, oplevering en vervolg

Voeg `docs/security-overview.md` toe met betekenis van statussen, meetdekking,
tokenconfiguratie, veroudering, beoordelingsregels en troubleshooting.
Werk API-referentie en relevante navigatie bij.

Lever elke fase controleerbaar op, maar verklaar het dashboard pas klaar als
A–D en de acceptatiechecks werken. Eindrapport bevat gewijzigde bestanden,
testresultaten, ontbrekende live verificatie en expliciete restscope.

Alleen commit/push/deploy wanneer de gebruiker uitvoering inclusief shipping vraagt.
Bij shipping: blijf op main, voer vereiste checks uit, commit scoped, push,
wacht op geslaagde Verify en Publish Docker Images. Er is nu geen VM/cluster
om te verversen. Maak die niet aan. Latere Portal-rollout loopt via GitOps;
Management VM alleen na publish-success en met de juiste gepubliceerde SHA-tag.

Vervolgfasen, niet onderdeel van versie 1: runtime-digests meten en matchen,
derdepartij-images inventariseren/scannen, bereikbaarheid meten, MFA/rechten toetsen,
detectieketen testen en hersteltestbewijs verzamelen. Iedere collector krijgt
eigen versheid, bewijs en least-privilege credentials. Geen van deze onderdelen
mag tot die tijd als gecontroleerd worden getoond.
