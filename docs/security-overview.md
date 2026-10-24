# Beveiligingsoverzicht

De Portal toont bij **Beheer → Beveiliging** de status van de zeven gepubliceerde
Twinbox-images. De Management UI toont vóór de installatie een korte samenvatting.
Er is momenteel geen draaiende Management VM of cluster om live te controleren.

De dagelijkse workflow `Monitor Published Images` scant de zeven images op hun
vastgelegde digest en bewaart een compleet `twinbox-security-report` artifact.
De technische issue blijft een korte werklijst. De rapportage bevat ook lage en
gemiddelde bevindingen en de originele scannerclassificatie.

## Betekenis

- **Actie nodig**: minstens één bevinding is beoordeeld als van toepassing.
- **Beoordeling nodig**: bevindingen zonder toereikend bewijs blijven open.
- **Geen open bevindingen binnen de gecontroleerde scope**: alleen de gemeten
  gepubliceerde images zijn vrij van open meldingen.
- **Onvoldoende actuele gegevens**: bronfout, ontbrekend image, onvolledig of
  meer dan 36 uur oud rapport. Eerdere resultaten blijven zichtbaar met foutmelding.
- **Niet gemeten**: live images, overige third-party images, netwerk, accounts,
  detectie en back-upherstel. Dit is geen groen beveiligingsoordeel.

Een nieuwe kwetsbaarheid is standaard `needs_review`. Een uitzondering voor
`not_affected` moet exact op pakket, distributie, release, versie en CVE passen,
met bron, documentatie en vervaldatum. De CI verifieert de checksum van de
opgegeven bronpagina; een gewijzigde of niet beschikbare bron laat de uitzondering
vervallen. De huidige regel betreft uitsluitend Debian Bookworm `zlib1g`
`1:1.2.13.dfsg-1` en CVE-2023-45853. De originele Critical-classificatie blijft
zichtbaar in de detailweergave.

## Gegevenstoegang

De Manager API kan een optionele `TWINBOX_SECURITY_GITHUB_TOKEN` gebruiken met
uitsluitend `Actions: read` voor deze repository. Voeg die toe aan de geheime
configuratie van de Management VM; plaats de waarde niet in Git. De API haalt
alleen het rapport-artifact van een geslaagde run op `main` op en bewaart de
laatste geldige versie onder zijn data-directory. Zonder token meldt het scherm
expliciet dat de bron niet is geconfigureerd. De Portal controleert de
beheerderssessie op de server voordat zij gegevens doorgeeft.

De API biedt `GET /api/security/overview?scope=published` en
`GET /api/security/images/:imageKey`. `scope=runtime` levert `not_measured` zolang
er geen actuele inventaris van draaiende image-digests is. De Portal gebruikt
`GET /api/admin/security` en `/api/admin/security/images/:imageKey`.

Bij fouten: controleer de laatste `Monitor Published Images` run, de aanwezigheid
van het rapport-artifact, de tokenrechten en de 36-uursversheid. Een geslaagde
eerdere scan overschrijft een latere scanfout niet in het dashboard.
