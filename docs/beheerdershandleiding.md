# Beheerdershandleiding - Afdeling Chat

Deze handleiding is voor de beheerder(s) die de chatserver installeren,
inrichten en onderhouden. Voor uitleg over het dagelijks gebruik (chatten,
bellen, bestanden delen), zie de [Gebruikershandleiding](gebruikershandleiding.md).

> De schermafbeeldingen zijn gemaakt met voorbeelddata om alle
> beheerfuncties te kunnen laten zien.

## Inhoud

1. [Hoe de app werkt (kort)](#hoe-de-app-werkt-kort)
2. [Vereisten](#vereisten)
3. [Installatie](#installatie)
4. [De server starten](#de-server-starten)
5. [Eerste keer inloggen als beheerder](#eerste-keer-inloggen-als-beheerder)
6. [Het tabblad Beheer](#het-tabblad-beheer)
7. [Een privéroom achteraf beheren](#een-priv%C3%A9room-achteraf-beheren)
8. [Onderhoud](#onderhoud)
9. [Problemen oplossen](#problemen-oplossen)
10. [Beveiligingsoverwegingen](#beveiligingsoverwegingen)

## Hoe de app werkt (kort)

- **Eén centrale server** (een PowerShell-script) host alles: de webpagina's,
  de chatgeschiedenis, geüploade bestanden én de live verbindingen. Iedereen
  op de afdeling opent gewoon een browser naar
  `http://<servernaam>:8080/`.
- **Inloggen gaat automatisch** via Integrated Windows Authentication: de
  server leest de Windows-identiteit (`NETWERK.TLD\gebruikersnaam`) die de
  browser meestuurt. Er is geen apart wachtwoord of gebruikersbeheer nodig.
- **Spraakgesprekken en scherm delen lopen via de server** (een "relay"),
  niet rechtstreeks tussen collega's. Dat is bewust zo gekozen: het werkt
  betrouwbaar binnen het bedrijfsnetwerk zonder extra infrastructuur zoals
  STUN/TURN-servers, met als afweging iets meer vertraging dan bijvoorbeeld
  Teams of Skype.
- **Alles draait op Windows PowerShell 5.1** (standaard aanwezig op Windows),
  met `System.Net.HttpListener` als ingebouwde webserver.

## Vereisten

- Een Windows-server of -pc met **Windows PowerShell 5.1**
  (controleer met `$PSVersionTable.PSVersion` in PowerShell).
- De servermachine moet lid zijn van hetzelfde Active Directory-domein als
  de gebruikers, zodat Integrated Windows Authentication werkt.
- Beheerdersrechten op die machine (voor de poortbinding), of een vooraf
  geregistreerde URL-ACL (zie [De server starten](#de-server-starten)).
- Bij de gebruikers: Chrome of Edge (voor scherm delen, microfoon en de
  moderne webtechnieken die de app gebruikt).

## Installatie

1. Kopieer de volledige projectmap (met de mappen `server/`, `wwwroot/`,
   `data/` en `uploads/`) naar de servermachine, bijvoorbeeld naar
   `D:\AfdelingChat\`.
2. Open `server\config\server.config.json` in een teksteditor en vul in elk
   geval `initialAdmins` in met jouw eigen account, zodat je meteen na de
   eerste start bij het Beheer-tabblad kunt:

   ```json
   {
     "departmentName": "Afdeling Chat",
     "prefixes": [ "http://+:8080/" ],
     "authentication": "IntegratedWindowsAuthentication",
     "dataDir": "..\\data",
     "uploadsDir": "..\\uploads",
     "wwwrootDir": "..\\wwwroot",
     "maxUploadSizeMb": 100,
     "messageHistoryLimit": 500,
     "screenFrameMaxBytes": 400000,
     "audioChunkMaxBytes": 200000,
     "initialAdmins": [
       "NETWERK.TLD\\jouw-gebruikersnaam"
     ]
   }
   ```

   - `prefixes`: op welke poort(en) de server luistert. Pas dit aan als
     poort 8080 al in gebruik is.
   - `initialAdmins`: één of meer accounts die vanaf de allereerste start
     beheerder zijn. Later kun je via het Beheer-tabblad ook andere
     collega's tot beheerder promoveren (zie verderop) - die hoeven dan niet
     in dit bestand te staan.

3. Laat `dataDir`, `uploadsDir` en `wwwrootDir` staan zoals ze zijn, tenzij
   je bewust een andere mapstructuur wilt. Deze mappen worden bij de eerste
   start automatisch aangemaakt/gevuld.

## De server starten

Open **PowerShell als Administrator** en start het opstartscript:

```powershell
cd D:\AfdelingChat\server
.\Start-ChatServer.ps1
```

Je ziet dan zoiets als:

```
=== Afdeling Chat - chatserver gestart ===
Luistert op: http://+:8080/
wwwroot:     D:\AfdelingChat\wwwroot
data:        D:\AfdelingChat\data
uploads:     D:\AfdelingChat\uploads
Druk op Ctrl+C om te stoppen.
```

Laat dit venster openstaan (of richt de server later in als Windows-dienst /
geplande taak die bij het opstarten van de server automatisch draait - dat
valt buiten deze handleiding, maar elk hulpmiddel dat een PowerShell-script
continu kan laten draaien werkt hiervoor, zoals NSSM of Taakplanner met
"Opnieuw uitvoeren bij falen").

### Draai je liever niet als Administrator?

Registreer dan eenmalig een URL-ACL met een beheerdersaccount, en start de
server daarna gewoon als normale gebruiker:

```powershell
netsh http add urlacl url=http://+:8080/ user="NETWERK.TLD\gebruikersnaam-of-groep"
New-NetFirewallRule -DisplayName "Afdeling Chat" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```

### HTTPS (optioneel)

Standaard draait de server over gewone HTTP, wat prima werkt binnen een
vertrouwd bedrijfsnetwerk (de Windows-aanmelding werkt ook over HTTP). Wil
je toch TLS, bind dan met `netsh http add sslcert` een certificaat aan de
poort en wijzig het prefix naar `https://+:8443/` in
`server.config.json` - de rest van de configuratie blijft gelijk.

## Eerste keer inloggen als beheerder

Open op je eigen werkplek `http://<servernaam>:8080/` in Chrome of Edge. Je
wordt automatisch herkend via je Windows-sessie:

![Inlogscherm terwijl de Windows-sessie wordt herkend](images/01-inloggen.png)

Sta je in `initialAdmins`, dan zie je meteen een extra tabblad **Beheer**
naast Chats, Oproepen & scherm delen en Instellingen.

## Het tabblad Beheer

Dit is het hart van het beheer: app-configuratie, een nieuwe openbare room
aanmaken, aanvragen voor privérooms afhandelen en gebruikers beheren staan
allemaal op één pagina.

![Het volledige Beheer-tabblad: configuratie, nieuwe room, aanvragen en gebruikers](images/09-beheer-overzicht.png)

### App-configuratie

Links bovenaan pas je de instellingen aan die voor de hele afdeling gelden:

- **Afdelingsnaam** - verschijnt linksboven in de navigatiebalk en als
  paginatitel.
- **Maximale uploadgrootte (MB)** - de bovengrens voor bestanden die
  gebruikers delen in de chat.
- **Berichtgeschiedenis per room (aantal)** - hoeveel berichten per
  chatroom bewaard blijven; oudere berichten worden automatisch
  opgeruimd zodra dit aantal wordt overschreden.

Klik op **Opslaan** om de wijzigingen meteen door te voeren.

### Een nieuwe openbare chatroom aanmaken

Onder **Nieuwe openbare chatroom** vul je een naam en optioneel een
onderwerp in en klik je op **Aanmaken**. De room is direct zichtbaar voor
iedereen op de afdeling, en - zoals bij openbare rooms hoort - is elke
gebruiker die erin chat automatisch ook manager (mag naam/onderwerp
aanpassen).

### Aanvragen voor privérooms afhandelen

Rechtsboven zie je openstaande aanvragen voor privérooms, met wie de
aanvraag heeft ingediend, het opgegeven doel en de voorgestelde leden:

- **Goedkeuren** maakt de room daadwerkelijk aan. De aanvrager wordt
  standaard manager en de voorgestelde leden worden lid. (Wil je een andere
  verdeling van managers/leden, dan kun je dat na het aanmaken direct
  aanpassen via ["Een privéroom beheren"](#een-priv%C3%A9room-achteraf-beheren).)
- **Afwijzen** verwerpt de aanvraag; er wordt geen room aangemaakt.

### Gebruikers beheren

Onderaan rechts staat een overzicht van alle gebruikers die ooit hebben
ingelogd, met hun laatst geziene tijdstip, of ze op dit moment online zijn,
en een selectievakje **Beheerder**. Vink dit aan om iemand beheerdersrechten
te geven, of uit om ze weer in te trekken.

> Gebruikers die nog nooit hebben ingelogd, staan hier nog niet tussen - de
> lijst vult zich vanzelf zodra iemand voor het eerst de app opent.

## Een privéroom achteraf beheren

Managers van een privéroom (waaronder beheerders, altijd) kunnen leden en
managers aanpassen via **Beheer room** boven de berichten van die room op
het tabblad **Chats**.

![Leden en managers van een privéroom beheren](images/10-room-beheren.png)

- Voeg een gebruiker toe met het volledige `NETWERK.TLD\gebruikersnaam`
  formaat, en vink **Als manager toevoegen** aan als die persoon ook zelf
  leden moet kunnen beheren.
- Klik op **Verwijderen** naast een naam om iemand uit de room te
  verwijderen (dit verwijdert ook het managerschap, mocht die persoon
  manager zijn).
- Onderaan kun je de naam en het onderwerp van de room wijzigen.

Een openbare room verwijderen of een privéroom volledig opheffen kan
(vooralsnog) alleen via de API door een beheerder, niet via een knop in de
interface.

## Onderhoud

- **Data**: chatrooms, berichten, gebruikersinstellingen en bestandsmeta­data
  staan als JSON-bestanden in de map `data/` (en per room onder
  `data/messages/`). Geüploade bestanden zelf staan in `uploads/<roomId>/`.
  Neem deze twee mappen mee in je back-upstrategie.
- **Herstarten**: de server mag gewoon herstart worden (bijvoorbeeld na een
  configuratiewijziging in `server.config.json`, die alleen bij het
  opstarten wordt ingelezen). Actieve gesprekken/verbindingen worden dan
  verbroken, maar chatgeschiedenis en instellingen blijven bewaard.
- **Updates**: vervang de bestanden in `server/` en `wwwroot/` door een
  nieuwere versie en herstart de server. De map `data/` en `uploads/` hoef
  je niet aan te raken.

## Problemen oplossen

**De server start niet / "Kon de HttpListener niet starten".**
Meestal is de poort al in gebruik door een ander programma, of ontbreken de
rechten voor de binding. Start PowerShell als Administrator, of registreer
eerst de URL-ACL zoals beschreven bij [De server starten](#de-server-starten).

**Gebruikers krijgen een foutmelding bij het inloggen / blijven hangen op
"Bezig met aanmelden...".**
Controleer of de servermachine en de gebruiker in hetzelfde Active
Directory-domein zitten, en of de gebruiker de pagina opent in Chrome of
Edge (niet via een externe/anonieme verbinding buiten het domein - Integrated
Windows Authentication werkt alleen binnen het vertrouwde netwerk).

**Chatberichten of oproepen komen niet aan / blijven "verbinden".**
Controleer of er geen firewall of proxy tussen gebruikers en de server in
zit die WebSocket-verkeer (`ws://.../ws`) blokkeert. Reguliere paginabezoeken
(HTTP) kunnen dan nog wel werken, terwijl live chat/bellen uitvalt.

**Een upload mislukt met "Bestand is groter dan de limiet".**
Verhoog zo nodig `maxUploadSizeMb` bij [App-configuratie](#app-configuratie).

## Beveiligingsoverwegingen

- Er is geen aparte inlogstap: toegang tot de app is zo veilig als de
  toegang tot het bedrijfsnetwerk/domein zelf. Zorg dat de server niet
  bereikbaar is vanaf buiten het vertrouwde netwerk zonder aanvullende
  maatregelen (VPN, firewallregels).
- Standaard loopt al het verkeer over gewone HTTP; overweeg HTTPS (zie
  hierboven) als vertrouwelijkheid van het netwerkverkeer zelf een vereiste
  is.
- Beheerdersrechten in de app (het Beheer-tabblad) zijn onafhankelijk van
  Windows-beheerdersrechten - het gaat puur om wie in `initialAdmins` staat
  of later via de Gebruikers-tabel is gepromoveerd.
