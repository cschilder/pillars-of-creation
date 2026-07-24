# Afdeling Chat

Een lokaal gehoste chat-applicatie voor de afdeling: PowerShell-backend op
een gewone `System.Net.Sockets.TcpListener` (bewust **geen**
`System.Net.HttpListener`, zie hieronder waarom), een HTML/Canvas front-end
en styling/lay-out op basis van een **lokaal gevendorde** build van
[Vanilla Framework](https://vanillaframework.io/) (geen CDN).

Dit is nadrukkelijk **geen Skype-kloon** (dat mag ook niet), maar een eigen
opzet met vergelijkbare functionaliteit: chatrooms, bestanden delen, scherm
delen en spraakgesprekken.

> **Handleidingen met schermafbeeldingen:**
> [Gebruikershandleiding](docs/gebruikershandleiding.md) (chatten, bellen,
> scherm delen, instellingen) en
> [Beheerdershandleiding](docs/beheerdershandleiding.md) (installatie,
> configuratie, gebruikers- en roombeheer). Dit README richt zich vooral op
> de technische opzet.

## ⚠️ Belangrijk: inloggen is niet geverifieerd

Gebruikers loggen in door zelf een naam in te typen - `NETWERK.TLD\gebruikersnaam`
of gewoon een korte nickname zoals `jansen` mag allebei - dit wordt **niet** gecontroleerd tegen Active Directory of een
wachtwoord. Wie er ook toegang heeft tot de server, kan zich voordoen als
elke andere gebruiker. Dit is een bewuste keuze omdat er geen
beheerdersrechten beschikbaar waren om `HttpListener` met Integrated
Windows Authentication op te zetten (zie
["Waarom geen HttpListener"](#waarom-geen-httplistener-en-dus-geen-integrated-windows-authentication)
hieronder). **Draai deze server alleen binnen een netwerk dat je al
vertrouwt**, en behandel het niet als een vervanging voor echte
authenticatie.

## Functionaliteit

- **Tabbladen-GUI**: Chats, Oproepen &amp; scherm delen, Instellingen, en
  (voor beheerders) Beheer.
- **Login zonder wachtwoord, wel zonder verificatie**: gebruikers typen
  eenmalig een naam of nickname in (`NETWERK.TLD\gebruikersnaam` of gewoon
  `jansen`); de server onthoudt dat via een cookie. Zie de
  beveiligingswaarschuwing hierboven.
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
  Windows, geen extra installatie nodig).
- Elke inkomende verbinding (statisch bestand, API-call, of een langdurig
  open WebSocket voor chat/gesprek) krijgt zijn **eigen PowerShell
  Runspace**, zodat één traag verzoek of open gesprek de rest van de
  afdeling niet blokkeert.

### Waarom geen HttpListener (en dus geen Integrated Windows Authentication)

`System.Net.HttpListener` is gebouwd op http.sys, en **elke** binding
daarvan - inclusief `http://localhost:PORT/` - vereist ofwel dat het
script als Administrator draait, ofwel een vooraf door een beheerder
geregistreerde URL-reservering (`netsh http add urlacl`). Zonder iemand
met adminrechten in de buurt is dat een doodlopende weg. Deze server draait
daarom op een gewone `System.Net.Sockets.TcpListener`: het openen van een
normale TCP-poort is op Windows nooit een verhoogde actie geweest. De
keerzijde is dat Integrated Windows Authentication (die specifiek via
http.sys werkt) hiermee ook wegvalt - vandaar de zelf-ingevulde,
ongeverifieerde gebruikersnaam hierboven.

`server/modules/MiniHttp.psm1` implementeert daarom zelf het benodigde
stukje HTTP/1.1 (request parsen, response schrijven) en de WebSocket
opening handshake (RFC 6455) met de hand, en levert een object terug dat
er voor de rest van de code (`Http.psm1`, `Api.psm1`, `WebSocketHub.psm1`)
precies zo uitziet als wat `HttpListener` zou hebben gegeven - daar
hoefde dus verder niets aan te veranderen.

## Vereisten

- Windows Server of Windows 10/11 met **Windows PowerShell 5.1**
  (`$PSVersionTable.PSVersion`).
- **Geen** beheerdersrechten nodig - een gewoon gebruikersaccount volstaat
  om de server te starten.
- Chrome of Edge bij de gebruikers (voor `getDisplayMedia`, `MediaRecorder`
  en ES modules; Firefox werkt in de praktijk ook, Internet Explorer niet).

## Starten

1. Zet in `server/config/server.config.json` minimaal je eigen
   `initialAdmins` (bv. `"NETWERK.TLD\\jouwaccount"`, of gewoon een korte
   nickname zoals `"jouwnaam"`), zodat je bij de eerste start toegang hebt
   tot het Beheer-tabblad - log daarna in met exact diezelfde naam.
2. Start de server (een heel gewoon, niet-verhoogd PowerShell-venster
   volstaat):

   ```powershell
   cd server
   .\Start-ChatServer.ps1
   ```

3. Open op elke werkplek in de browser: `http://<servernaam>:8080/`.

Wil je de server ook bereikbaar maken voor collega's op andere machines,
open dan de gebruikte poort in de Windows Firewall (dit commando vereist
zelf wel adminrechten - vraag dit eventueel eenmalig aan IT, het is een
firewallregel, geen aparte poortreservering):

```powershell
New-NetFirewallRule -DisplayName "Afdeling Chat" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```

Zonder deze firewallregel werkt de server nog steeds prima voor jezelf op
`http://localhost:8080/`; collega's op andere machines kunnen er dan alleen
niet bij.

### Poort aanpassen

Pas `port` aan in `server/config/server.config.json`.

## Mappenstructuur

```
server/
  Start-ChatServer.ps1        Opstartscript (TcpListener + accept-loop, geen adminrechten nodig)
  config/server.config.json   Poort, paden, initiële beheerders
  modules/
    MiniHttp.psm1              Eigen HTTP/1.1-parsing + WebSocket-handshake (i.p.v. HttpListener)
    Http.psm1                  Statische bestanden, JSON responses, multipart-parser
    Store.psm1                 JSON-opslag (rooms/users/berichten/bestanden) met locking
    Auth.psm1                  Cookie-gebaseerde (ongeverifieerde) identiteit
    WebSocketHub.psm1          WebSocket-verbindingsregister + chat/presence/call-relay
    Api.psm1                   REST routes onder /api/*, incl. /api/login en /api/logout
    ConnectionWorker.ps1        Per-verbinding entrypoint (draait in een eigen Runspace)
wwwroot/
  index.html                  SPA-shell met tabbladen + inlogformulier
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

- **Geen echte authenticatie** - zie de waarschuwing bovenaan dit
  document. Elke gebruikersnaam wordt vertrouwd zonder controle.
- Spraak/scherm delen is server-relayed, geen WebRTC: geschikt voor
  gesprekken binnen een afdeling op hetzelfde netwerk, niet voor
  grootschalige videoconferenties.
- Er is geen end-to-end encryptie; verkeer is zo veilig als het interne
  netwerk.
- Geen HTTP keep-alive: elk verzoek (elk bestand, elke API-call) is zijn
  eigen TCP-verbinding. Prima voor een LAN-app met een handvol
  gebruikers, minder efficiënt dan een productie-webserver onder zware
  belasting.
- De WebSocket-clientregistratie leeft in het geheugen van het
  serverproces; een herstart van de server sluit actieve verbindingen
  (chatrooms, berichten, bestanden en gebruikersinstellingen blijven wel
  bewaard in `data/` en `uploads/`).
