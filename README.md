# Afdeling Chat

Een lokaal gehoste chat-applicatie voor de afdeling: PowerShell-backend
(`System.Net.HttpListener`), een HTML/Canvas front-end en styling/lay-out op
basis van een **lokaal gevendorde** build van
[Vanilla Framework](https://vanillaframework.io/) (geen CDN). Gebruikers
loggen in met hun huidige Windows-sessie (`NETWERK.TLD\gebruikersnaam`) via
Integrated Windows Authentication - er is geen apart wachtwoordscherm.

Dit is nadrukkelijk **geen Skype-kloon** (dat mag ook niet), maar een eigen
opzet met vergelijkbare functionaliteit: chatrooms, bestanden delen, scherm
delen en spraakgesprekken.

> **Handleidingen met schermafbeeldingen:**
> [Gebruikershandleiding](docs/gebruikershandleiding.md) (chatten, bellen,
> scherm delen, instellingen) en
> [Beheerdershandleiding](docs/beheerdershandleiding.md) (installatie,
> configuratie, gebruikers- en roombeheer). Dit README richt zich vooral op
> de technische opzet.

## Functionaliteit

- **Tabbladen-GUI**: Chats, Oproepen &amp; scherm delen, Instellingen, en
  (voor beheerders) Beheer.
- **Windows-sessie login**: geen wachtwoordveld; de browser onderhandelt
  automatisch met NTLM/Negotiate en de server leest `NETWERK.TLD\gebruiker`
  uit de geverifieerde `HttpListenerContext`.
- **Openbare chatrooms**: door een beheerder aangemaakt, zichtbaar voor de
  hele afdeling; iedereen die lid is, is ook manager (kan onderwerp/naam
  wijzigen).
- **Privé chatrooms op verzoek**: elke gebruiker kan een privéroom
  aanvragen (naam, doel, voorgestelde leden); een beheerder keurt goed of
  af en stelt daarbij managers/leden in. Managers van een privéroom kunnen
  daarna zelf leden toevoegen/verwijderen en managers aanwijzen.
- **Bestanden delen**: upload/download per chatroom (multipart upload,
  opgeslagen onder `uploads/<roomId>/...`, verschijnt als berichttype
  "bestand" in de chat).
- **Spraakgesprekken**: microfoon-audio wordt in korte fragmenten
  (~250 ms) opgenomen en via de server doorgestuurd naar iedereen anders
  in dezelfde room-call.
- **Scherm/programma's delen**: de browser vangt het scherm met
  `getDisplayMedia()`, tekent frames op een `<canvas>`, comprimeert ze als
  JPEG en stuurt ze via de server door; ontvangers tekenen de frames op hun
  eigen `<canvas>`.
- **App-configuratiescherm** (Beheer-tab): afdelingsnaam, maximale
  uploadgrootte, aantal bewaarde berichten per room.
- **Gebruikersconfiguratiescherm** (Instellingen-tab): weergavenaam
  overschrijven, thema (licht/donker), meldingsgeluid aan/uit.

## Architectuurkeuzes (en de beperkingen die daarbij horen)

Dit project bouwt bewust **niet** op WebRTC/STUN/TURN - dat is externe
infrastructuur en dus niet "lokaal, alleen PowerShell". In plaats daarvan:

- Eén centrale PowerShell-server host alles; iedereen op de afdeling
  verbindt via de browser naar `http://<servernaam>:8080/`.
- Spraak en scherm delen lopen **via de server** (relay over de
  WebSocket-verbinding), niet peer-to-peer. Dat is eenvoudiger, werkt
  betrouwbaar binnen het lokale netwerk, maar heeft wat meer latency dan
  "echte" WebRTC en is niet geschikt voor grote videostreams - het is
  bedoeld voor spraak en (laag-fps) scherm delen binnen een afdeling.
- Target-runtime is **Windows PowerShell 5.1** (overal al aanwezig op
  Windows, geen extra installatie nodig). `System.Net.HttpListener`
  ondersteunt WebSockets ook onder .NET Framework 4.5+
  (`HttpListenerContext.AcceptWebSocketAsync`).
- Elke inkomende verbinding (statisch bestand, API-call, of een langdurig
  open WebSocket voor chat/gesprek) krijgt zijn **eigen PowerShell
  Runspace**, zodat één traag verzoek of open gesprek de rest van de
  afdeling niet blokkeert.

## Vereisten

- Windows Server of Windows 10/11 met **Windows PowerShell 5.1**
  (`$PSVersionTable.PSVersion`).
- De machine (of gebruikers) moet lid zijn van hetzelfde Active Directory
  domein als de gebruikers, zodat Integrated Windows Authentication werkt.
- Chrome of Edge bij de gebruikers (voor `getDisplayMedia`, `MediaRecorder`
  en ES modules; Firefox werkt in de praktijk ook, Internet Explorer niet).

## Starten

1. Open **PowerShell als Administrator** op de servermachine (nodig voor
   de `http://+:8080/` binding en Integrated Windows Authentication).
2. Zet in `server/config/server.config.json` minimaal je eigen
   `initialAdmins` (bv. `"NETWERK.TLD\\jouwaccount"`), zodat je bij de
   eerste start toegang hebt tot het Beheer-tabblad.
3. Start de server:

   ```powershell
   cd server
   .\Start-ChatServer.ps1
   ```

4. Open op elke werkplek in de browser: `http://<servernaam>:8080/`.

Wil je liever niet als Administrator draaien? Registreer dan eenmalig een
URL-ACL voor de gebruikte poort (met een beheerdersaccount):

```powershell
netsh http add urlacl url=http://+:8080/ user="NETWERK.TLD\gebruikersnaam of groep"
```

en open de poort in de Windows Firewall:

```powershell
New-NetFirewallRule -DisplayName "Afdeling Chat" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```

### Poort/adres aanpassen

Pas `prefixes` aan in `server/config/server.config.json`, bijvoorbeeld
`"http://+:8080/"` naar een andere poort, of naar een specifieke hostnaam
in plaats van de wildcard `+`.

### HTTPS

Deze server draait standaard over gewoon HTTP, wat prima is binnen een
vertrouwd bedrijfsnetwerk (NTLM-onderhandeling werkt ook over HTTP). Wil je
TLS, dan kun je met `netsh http add sslcert` een certificaat aan de poort
binden en het prefix wijzigen naar `https://+:8443/`; de rest van de code
verandert niet.

## Mappenstructuur

```
server/
  Start-ChatServer.ps1        Opstartscript (HttpListener + Windows Auth + accept-loop)
  config/server.config.json   Poort, paden, initiële beheerders
  modules/
    Http.psm1                 Statische bestanden, JSON responses, multipart-parser
    Store.psm1                JSON-opslag (rooms/users/berichten/bestanden) met locking
    Auth.psm1                 Koppelt de geverifieerde Windows-identiteit aan een profiel
    WebSocketHub.psm1         WebSocket-verbindingsregister + chat/presence/call-relay
    Api.psm1                  REST routes onder /api/*
    ConnectionWorker.ps1      Per-verbinding entrypoint (draait in een eigen Runspace)
wwwroot/
  index.html                  SPA-shell met tabbladen
  css/app.css                 App-specifieke stijl bovenop Vanilla Framework
  vendor/vanilla-framework/   Lokaal gecompileerde Vanilla Framework CSS (LGPLv3)
  js/                         ES-modules: api, ws, state, ui, chat, admin, settings,
                               files, call, screenshare, app (bootstrap)
data/                         JSON-opslag, automatisch aangemaakt bij eerste start
uploads/                      Geüploade bestanden, per room-map
```

## Vanilla Framework lokaal vendoren

`wwwroot/vendor/vanilla-framework/vanilla-framework.min.css` is een
volledige build, gecompileerd uit de officiële `vanilla-framework`
npm-package (`@import 'vanilla-framework'; @include vanilla;`, zoals in de
upstream README beschreven) met `sass --style=compressed`. Er wordt dus
niets gehotlinkt vanaf een CDN. Wil je een nieuwere versie vendoren, herhaal
dan dat compilatiestapje met een recentere `vanilla-framework`-versie en
vervang het bestand.

## Beheer

Log in als een account uit `initialAdmins` (of laat een bestaande
beheerder je via het Beheer-tabblad promoveren) om:

- de afdelingsnaam, uploadlimiet en bewaartermijn van berichten aan te
  passen;
- nieuwe **openbare** chatrooms aan te maken;
- aanvragen voor **privé** chatrooms goed te keuren/af te wijzen (met
  eigen keuze van managers/leden);
- gebruikers tot beheerder te promoveren of te degraderen.

## Bekende beperkingen

- Spraak/scherm delen is server-relayed, geen WebRTC: geschikt voor
  gesprekken binnen een afdeling op hetzelfde netwerk, niet voor
  grootschalige videoconferenties.
- Er is geen end-to-end encryptie; verkeer is zo veilig als het interne
  netwerk (en optioneel HTTPS, zie hierboven).
- De WebSocket-clientregistratie leeft in het geheugen van het
  serverproces; een herstart van de server sluit actieve verbindingen
  (chatrooms, berichten, bestanden en gebruikersinstellingen blijven wel
  bewaard in `data/` en `uploads/`).
