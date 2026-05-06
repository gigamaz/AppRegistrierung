# AppRegistrierung - Entra ID App Registration Tool

## Übersicht

PowerShell-Script zur Erstellung von Entra ID (ehemals Azure AD) App-Registrierungen. Unterstützt sowohl Einzelregistrierung als auch Batch-Verarbeitung per CSV-Datei.

## Features

- **Einzel- und Batch-Modus**: Interaktive Erstellung oder Massenverarbeitung via CSV
- **Automatische Validierung**: Prüft vor der Erstellung, ob die App bereits existiert
- **Owner-Verwaltung**: Sucht Benutzer per Suche und bietet Auswahlvorschläge
- **User-Erstellung**: Falls kein Owner gefunden wird, kann direkt ein neuer Benutzer angelegt werden
- **Tenant-Auswahl**: Automatische Erkennung mit Bestätigung
- **Redirect URI**: Optional im Einzelmodus erfassbar
- **CSV-Export**: Nach jedem Lauf mit App-Name, App ID, Tenant ID und Owner
- **Neue Benutzer**: UPN wird aus Name und Tenant-Domain des Tenants erzeugt, keine manuelle UPN-Eingabe mehr

## Voraussetzungen

- PowerShell 5.1 oder höher
- Microsoft.Graph PowerShell SDK

### Installation der Module

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Erforderliche Module (werden automatisch geladen):
- Microsoft.Graph.Applications
- Microsoft.Graph.Users
- Microsoft.Graph.Identity.DirectoryManagement

## Verwendung

```powershell
.\AppRegistrierung.ps1
```

## Fortsetzung

- Der aktuelle Arbeitsstand steht in `SESSION_HANDOFF.md`.
- Die nächsten konkreten Schritte stehen in `NEXT_STEPS.md`.

## Ablauf

### 1. Authentifizierung (Voreinstellung: Interaktiv)

- **[1] Interaktiv (Browser/MFA)** - Standard bei ENTER
- **[2] Benutzername + Passwort** - Nur ohne MFA

### 2. Tenant-Auswahl

- Tenant-ID oder Domain eingeben (leer = Standardmandant)
- Automatische Anzeige der Tenant-Informationen
- Bestätigung mit ENTER (Standard: Ja)

### 3. Modus-Auswahl (Voreinstellung: Einzeln)

- **[E] Einzelne App-Registrierung** - Standard bei ENTER
- **[B] Batch-Verarbeitung per CSV**

### 4. Owner-Suche (Einzel-Modus)

- Eingabe von mindestens 3 Zeichen (Teil des Namens oder UPN)
- Wildcard-Suche zeigt bis zu 10 Vorschläge
- Auswahl per Nummer

### 5. Redirect URI (optional)

- Im Einzelmodus kann nach dem App-Namen eine Redirect URI angegeben werden
- ENTER = Überspringen

## CSV-Format (Batch-Modus)

### Pflichtfelder

| Spalte | Beschreibung |
|--------|--------------|
| AppName | Name der App-Registrierung |
| OwnerUPN | UPN des Owners (z.B. max.muster@contoso.com) |

### Optionale Felder

| Spalte | Beschreibung | Standard |
|--------|--------------|----------|
| Description | Beschreibung der App | leer |
| SignInAudience | Zielgruppe für Anmeldung | AzureADMyOrg |

### Beispiel CSV (Semikolon-getrennt)

```csv
AppName;OwnerUPN;Description;SignInAudience
MeineApp;max.muster@contoso.com;Test App;AzureADMyOrg
AndereApp;anna.beispiel@contoso.com;Produktiv App;AzureADMultipleOrgs
```

## Berechtigungen

Das Script benötigt folgende Microsoft Graph Berechtigungen:

- `Application.ReadWrite.All` - Erstellen von App-Registrierungen
- `User.Read.All` - Suche nach Benutzern/Ownern
- `User.ReadWrite.All` - Erstellen neuer Benutzer
- `Directory.Read.All` - Lesen von Tenant-Informationen

## Änderungen (Version 1.1)

- Authentifizierung: ENTER wählt "Interaktiv" (Standard)
- Tenant-Bestätigung: ENTER bestätigt mit "Ja", kein Abbruch möglich
- Modus-Auswahl: ENTER wählt "Einzeln" (Standard)
- Owner-Suche: Wildcard-Suche mit Vorschlagsliste ab 3 Zeichen

## Änderungen (Version 1.2)

- **User-Erstellung**: Bei nicht gefundenem Owner kann ein neuer Benutzer erstellt werden (Vorname, Nachname, on-prem UPN, sicheres Passwort)
- **Ergebnis-Export**: Automatischer CSV-Export nach jedem Lauf mit den Kerndaten
- **Redirect URI**: Optionale Redirect URI im Einzelmodus
- **Berechtigungen erweitert**: Benötigt nun zusätzlich `User.ReadWrite.All` für User-Erstellung
- Nach dem Export wird der vollständige Pfad der CSV-Datei angezeigt

## Versionierung

- Jede Ausführung erzeugt eine Buildnummer im Format `yyyyMMdd_HHmmss`
- Diese Buildnummer steht im Skriptbanner und im Export-Dateinamen

## Bekannte Einschränkungen

- Batch-Modus erfordert korrektes CSV-Format (Semikolon oder Komma)
- Owner-Suche zeigt maximal 10 Ergebnisse an

## Fehlerbehebung

### Verbindung fehlgeschlagen
- Prüfen Sie die Tenant-ID/Domain
- Stellen Sie sicher, dass MFA bei interaktiver Anmeldung funktioniert

### Owner nicht gefunden
- Verwenden Sie den Einzel-Modus mit der neuen Suchfunktion
- Prüfen Sie die Schreibweise des UPN
