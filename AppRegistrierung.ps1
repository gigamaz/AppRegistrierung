#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Legt Entra ID App-Registrierungen an und weist einen Owner zu.

.DESCRIPTION
    Unterstuetzt Einzelregistrierung (interaktiv) und Batch-Verarbeitung per CSV.
    Prueft vor der Anlage:
      - Ob die App-Registrierung bereits existiert
      - Ob der angegebene Owner im Tenant vorhanden ist

    CSV-Format (Pflichtfelder): AppName, OwnerUPN
    Optionale Felder im CSV:   Description, SignInAudience

.EXAMPLE
    .\New-EntraAppRegistration_claude_v1.0.ps1

.NOTES
    Version: 1.0
    Benoetigt Microsoft.Graph PowerShell SDK:
      Install-Module Microsoft.Graph -Scope CurrentUser
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ScriptVersion = "1.3"
$ScriptBuild = Get-Date -Format "yyyyMMdd_HHmmss"

# ==============================================================
# Hilfsfunktionen
# ==============================================================

function Get-TenantInfo {
    try {
        $org = Get-MgOrganization -ErrorAction Stop | Select-Object -First 1
        $defaultDomain = $org.VerifiedDomains | Where-Object { $_.IsDefault } | Select-Object -First 1
        return [PSCustomObject]@{
            DisplayName = $org.DisplayName
            Id          = $org.Id
            Domain      = if ($defaultDomain) { $defaultDomain.Name } else { "" }
        }
    } catch {
        return $null
    }
}

function Get-MailNickname {
    param([string]$UserPrincipalName)

    $mailNickname = ($UserPrincipalName -split '@')[0]
    $mailNickname = $mailNickname -replace '[^a-zA-Z0-9._-]', ''

    if ([string]::IsNullOrWhiteSpace($mailNickname)) {
        $mailNickname = "user$(Get-Random -Minimum 1000 -Maximum 9999)"
    }

    if ($mailNickname.Length -gt 64) {
        $mailNickname = $mailNickname.Substring(0, 64)
    }

    return $mailNickname
}

function New-SecurePassword {
    param([int]$Length = 16)

    if ($Length -lt 8) {
        $Length = 8
    }

    $upper = [char[]](65..90)
    $lower = [char[]](97..122)
    $digit = [char[]](48..57)
    $all   = $upper + $lower + $digit

    $chars = @(
        ($upper | Get-Random)
        ($lower | Get-Random)
        ($digit | Get-Random)
    )

    $chars += (1..($Length - 3) | ForEach-Object { $all | Get-Random })

    return (-join ($chars | Sort-Object { Get-Random }))
}

function Write-UserTemplateDocument {
    param(
        [Parameter(Mandatory = $true)]
        [object]$User,
        [Parameter(Mandatory = $true)]
        [string]$TenantAlias,
        [Parameter(Mandatory = $true)]
        [string]$TemporaryPassword
    )

    $templatePath = Join-Path $PSScriptRoot "template.md"
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "template.md nicht gefunden: $templatePath"
    }

    $content = Get-Content -LiteralPath $templatePath -Raw
    $displayName = if ($User.DisplayName) { $User.DisplayName } else { "" }
    $mailNickname = if ($User.MailNickname) { $User.MailNickname } else { ($User.UserPrincipalName -split '@')[0] }
    $safeName = $mailNickname -replace '[^a-zA-Z0-9._-]', '_'
    $values = @($displayName, $mailNickname, $TenantAlias, $TenantAlias, $TemporaryPassword)
    $parts = $content -split '%s', ($values.Count + 1)
    $rendered = ""

    for ($i = 0; $i -lt $values.Count; $i++) {
        $rendered += $parts[$i] + $values[$i]
    }
    $rendered += $parts[$values.Count]

    $outputPath = Join-Path (Get-Location) "Benutzer_${ScriptVersion}_${ScriptBuild}_${safeName}.md"
    Set-Content -Path $outputPath -Value $rendered -Encoding UTF8

    return $outputPath
}

function Get-AppRegistrationsByName {
    param([string]$DisplayName)

    try {
        $escaped = $DisplayName -replace "'", "''"
        return @(Get-MgApplication -Filter "displayName eq '$escaped'" -All -Property Id,AppId,DisplayName -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Get-TenantUser {
    param([string]$UPN)
    try {
        return Get-MgUser -UserId $UPN -ErrorAction Stop
    } catch {
        try {
            $escaped = $UPN -replace "'", "''"
            $results = Get-MgUser -Filter "mail eq '$escaped' or userPrincipalName eq '$escaped'" -ErrorAction Stop
            return ($results | Select-Object -First 1)
        } catch {
            return $null
        }
    }
}

function Search-TenantUser {
    param([string]$SearchTerm)
    try {
        $term = ($SearchTerm -replace '"', '').Trim()
        if ([string]::IsNullOrWhiteSpace($term)) {
            return @()
        }

        $queries = @(
            ('"DisplayName:{0}"' -f $term)
            ('"Mail:{0}"' -f $term)
            ('"UserPrincipalName:{0}"' -f $term)
        )

        $results = foreach ($query in $queries) {
            Get-MgUser -ConsistencyLevel eventual -Count userCount -Search $query -All -Property Id,DisplayName,Mail,UserPrincipalName -ErrorAction SilentlyContinue
        }

        return $results | Sort-Object Id -Unique | Select-Object -First 10
    } catch {
        return @()
    }
}

function New-TenantUser {
    param(
        [string]$FirstName,
        [string]$LastName,
        [string]$TenantDomain
    )
    
    $displayName = "$LastName $FirstName (Admin)"
    $password = New-SecurePassword -Length 16
    $mailNickname = Get-MailNickname -UserPrincipalName "$FirstName.$LastName"
    $mailNickname = $mailNickname.ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($TenantDomain)) {
        throw "Keine Tenant-Domain verfuegbar, UPN kann nicht automatisch erzeugt werden."
    }

    $userPrincipalName = "$mailNickname@$TenantDomain"
    
    $passwordProfile = @{
        Password = $password
        ForceChangePasswordNextSignIn = $true
    }
    
    $userParams = @{
        DisplayName       = $displayName
        UserPrincipalName = $userPrincipalName
        MailNickname      = $mailNickname
        AccountEnabled    = $true
        PasswordProfile   = $passwordProfile
    }
    
    try {
        $newUser = New-MgUser @userParams -ErrorAction Stop
        Write-Host "  Neuer Benutzer erstellt: $displayName" -ForegroundColor Green
        Write-Host "  UPN: $userPrincipalName" -ForegroundColor Cyan
        Write-Host "  MailNickname: $mailNickname" -ForegroundColor Cyan
        return [PSCustomObject]@{
            User = $newUser
            TemporaryPassword = $password
        }
    } catch {
        Write-Error "Fehler beim Erstellen des Benutzers: $($_.Exception.Message)"
        return $null
    }
}

function New-EntraAppWithOwner {
    param(
        [string]$AppName,
        [string]$OwnerUPN,
        [string]$TenantId,
        [string]$Description    = "",
        [string]$SignInAudience = "AzureADMyOrg",
        [string]$RedirectUri = "",
        [string]$TemporaryPassword = "",
        [string]$UserDocumentPath = ""
    )

    $result = [PSCustomObject]@{
        AppName    = $AppName
        Owner      = $OwnerUPN
        TenantId   = $TenantId
        RedirectUri = $RedirectUri
        TemporaryPassword = $TemporaryPassword
        UserDocumentPath = $UserDocumentPath
        Status     = "Fehler"
        AppId      = ""
        ObjectId   = ""
        Message    = ""
    }

    # 1. Existenzpruefung App-Registrierung
    $existingApps = Get-AppRegistrationsByName -DisplayName $AppName
    if ($existingApps.Count -gt 0) {
        $existingApp = $existingApps | Select-Object -First 1
        $result.Status  = "Uebersprungen"
        $result.Message = "App-Registrierung '$AppName' existiert bereits."
        $result.AppId   = $existingApp.AppId
        $result.ObjectId = $existingApp.Id
        Write-Warning "  [$AppName] $($result.Message)"
        return $result
    }

    # 2. Owner-Validierung
    Write-Host "  Pruefe Owner '$OwnerUPN'..." -ForegroundColor DarkGray
    $ownerObj = Get-TenantUser -UPN $OwnerUPN
    if ($null -eq $ownerObj) {
        $result.Status  = "Fehler"
        $result.Message = "Owner '$OwnerUPN' nicht im Tenant gefunden."
        Write-Warning "  [$AppName] $($result.Message)"
        return $result
    }
    Write-Host "  Owner gefunden: $($ownerObj.DisplayName) ($($ownerObj.UserPrincipalName))" -ForegroundColor DarkGray

    # 3. App-Registrierung anlegen
    try {
        $appParams = @{
            DisplayName    = $AppName
            SignInAudience = $SignInAudience
        }
        if ($Description) {
            $appParams["Notes"] = $Description
        }
        if ($RedirectUri) {
            $appParams["Web"] = @{ RedirectUris = @($RedirectUri) }
        }

        $app = New-MgApplication @appParams -ErrorAction Stop
        $result.AppId    = $app.AppId
        $result.ObjectId = $app.Id
        Write-Host "  App erstellt: $AppName  |  AppId: $($app.AppId)" -ForegroundColor Green
    } catch {
        $result.Status  = "Fehler"
        $result.Message = "Fehler beim Erstellen der App: $_"
        Write-Error "  [$AppName] $($result.Message)"
        return $result
    }

    # 4. Owner zuweisen
    try {
        $ownerRef = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($ownerObj.Id)"
        }
        New-MgApplicationOwnerByRef -ApplicationId $app.Id -BodyParameter $ownerRef -ErrorAction Stop
        Write-Host "  Owner zugewiesen: $($ownerObj.DisplayName)" -ForegroundColor Green
        $result.Status  = "Erstellt"
        $result.Message = "Erfolgreich angelegt."
    } catch {
        $result.Status  = "Teilweise"
        $result.Message = "App erstellt, Owner-Zuweisung fehlgeschlagen: $_"
        Write-Warning "  [$AppName] $($result.Message)"
    }

    return $result
}

# ==============================================================
# Verbindung herstellen
# ==============================================================

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Entra ID App-Registrierung - Verwaltungstool" -ForegroundColor Cyan
Write-Host "  Version $ScriptVersion (Build $ScriptBuild)" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

$tenantInput = Read-Host "Tenant-ID oder Domain (leer = Standardmandant)"

Write-Host ""
Write-Host "Authentifizierung:" -ForegroundColor Yellow
Write-Host "  [1] Interaktiv (Browser / MFA) (Voreinstellung)"
Write-Host "  [2] Benutzername + Passwort (nur ohne MFA)"
$authChoice = Read-Host "Auswahl [1/2] (ENTER = 1)"
if ([string]::IsNullOrWhiteSpace($authChoice)) { $authChoice = "1" }

$connectParams = @{
    Scopes = @(
        "Application.ReadWrite.All"
        "User.Read.All"
        "User.ReadWrite.All"
        "Directory.Read.All"
    )
    NoWelcome = $true
}

if ($tenantInput -ne "") {
    $connectParams["TenantId"] = $tenantInput
}

if ($authChoice -eq "2") {
    $credential = Get-Credential -Message "Entra ID Anmeldedaten eingeben"
    $connectParams["Credential"] = $credential
}

Write-Host ""
Write-Host "Verbinde mit Microsoft Graph..." -ForegroundColor Yellow

try {
    Connect-MgGraph @connectParams -ErrorAction Stop
} catch {
    Write-Error "Verbindung fehlgeschlagen: $_"
    exit 1
}

    $tenantInfo = Get-TenantInfo
    $currentTenantId = if ($tenantInfo) { $tenantInfo.Id } else { (Get-MgContext).TenantId }
    $tenantDomain = if ($tenantInfo) { $tenantInfo.Domain } else { "" }
    $tenantAlias = if ($tenantDomain) { ($tenantDomain -replace '\.onmicrosoft\.com$', '') -replace '\.de$', '' } else { "" }
    if ($tenantInfo) {
    Write-Host ""
    Write-Host "Verbunden mit Tenant:" -ForegroundColor Green
    Write-Host "  Name   : $($tenantInfo.DisplayName)"
    Write-Host "  ID     : $($tenantInfo.Id)"
    Write-Host "  Domain : $($tenantInfo.Domain)"
    Write-Host ""

    $confirm = Read-Host "Ist dies der richtige Tenant? [J/N] (ENTER = J)"
    if ([string]::IsNullOrWhiteSpace($confirm)) { $confirm = "J" }
    if ($confirm -notmatch '^[JjYy]') {
        Write-Host "Tenant wird verwendet..." -ForegroundColor Yellow
    }
}

# ==============================================================
# Modus-Auswahl
# ==============================================================

Write-Host ""
Write-Host "Modus:" -ForegroundColor Yellow
Write-Host "  [E] Einzelne App-Registrierung (Voreinstellung)"
Write-Host "  [B] Batch-Verarbeitung per CSV"
$mode = Read-Host "Auswahl [E/B] (ENTER = E)"
if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "E" }

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($mode -match '^[Bb]') {

    # -- Batch-Modus ------------------------------------------
    Write-Host ""
    $csvPath = Read-Host "Pfad zur CSV-Datei"
    $csvPath = $csvPath.Trim('"').Trim("'")

    if (-not (Test-Path -LiteralPath $csvPath)) {
        Write-Error "Datei nicht gefunden: $csvPath"
        Disconnect-MgGraph
        exit 1
    }

    $entries = Import-Csv -Path $csvPath -Delimiter ";"
    if ($entries[0].PSObject.Properties.Name.Count -lt 2) {
        $entries = Import-Csv -Path $csvPath -Delimiter ","
    }

    if (-not $entries -or $entries.Count -eq 0) {
        Write-Error "CSV enthält keine Datenzeilen."
        Disconnect-MgGraph
        exit 1
    }

    $requiredCols = @("AppName", "OwnerUPN")
    foreach ($col in $requiredCols) {
        if ($col -notin $entries[0].PSObject.Properties.Name) {
            Write-Error "CSV fehlt Pflichtspalte: '$col'`nVorhandene Spalten: $($entries[0].PSObject.Properties.Name -join ', ')"
            Disconnect-MgGraph
            exit 1
        }
    }

    Write-Host ""
    Write-Host "$($entries.Count) Eintraege gefunden. Starte Verarbeitung..." -ForegroundColor Cyan
    Write-Host ""

    $i = 0
    foreach ($entry in $entries) {
        $i++
        Write-Host "[$i/$($entries.Count)] $($entry.AppName)" -ForegroundColor White

        if ($entry.PSObject.Properties.Name -contains "Description" -and $entry.Description) {
            $desc = $entry.Description
        } else {
            $desc = ""
        }
        if ($entry.PSObject.Properties.Name -contains "SignInAudience" -and $entry.SignInAudience) {
            $audience = $entry.SignInAudience
        } else {
            $audience = "AzureADMyOrg"
        }

        $r = New-EntraAppWithOwner `
                -AppName        $entry.AppName `
                -OwnerUPN       $entry.OwnerUPN `
                -TenantId       $currentTenantId `
                -Description    $desc `
                -SignInAudience $audience

        $allResults.Add($r)
    }

} else {

    # -- Einzel-Modus -----------------------------------------
    Write-Host ""
    $appName     = Read-Host "Name der App-Registrierung"

    $redirectUri = Read-Host "Redirect URI (optional, Enter = Ueberspringen)"
    $redirectUri = $redirectUri.Trim()
    $temporaryPassword = ""
    $userDocumentPath = ""

    # Owner mit Wildcard-Suche
    $ownerObj = $null
    while ($null -eq $ownerObj) {
        $ownerInput = Read-Host "Owner suchen (mindestens 3 Zeichen, Teil des Namens oder UPN)"
        if ($ownerInput.Length -lt 3) {
            Write-Host "  Bitte mindestens 3 Zeichen eingeben." -ForegroundColor Yellow
            continue
        }
        Write-Host "  Suche Benutzer..." -ForegroundColor DarkGray
        $users = Search-TenantUser -SearchTerm $ownerInput
        if ($users.Count -eq 0) {
            Write-Host "  Keine Benutzer gefunden." -ForegroundColor Yellow
            $createNew = Read-Host "  Neuen Benutzer erstellen? [J/N] (ENTER = N)"
            if ($createNew -match '^[JjYy]') {
                $firstName = Read-Host "  Vorname"
                $lastName = Read-Host "  Nachname"
                $newUserResult = New-TenantUser -FirstName $firstName -LastName $lastName -TenantDomain $tenantDomain
                if ($newUserResult) {
                    $ownerObj = $newUserResult.User
                    $ownerUPN = $newUserResult.User.UserPrincipalName
                    $temporaryPassword = $newUserResult.TemporaryPassword
                    $userDocumentPath = Write-UserTemplateDocument -User $newUserResult.User -TenantAlias $tenantAlias -TemporaryPassword $temporaryPassword
                    break
                } else {
                    Write-Host "  Erstellung fehlgeschlagen. Bitte erneut versuchen." -ForegroundColor Red
                    continue
                }
            } else {
                Write-Host "  Bitte erneut suchen." -ForegroundColor Yellow
                continue
            }
        }
        Write-Host "  Gefundene Benutzer:" -ForegroundColor Green
        for ($i = 0; $i -lt $users.Count; $i++) {
            Write-Host "    [$i] $($users[$i].DisplayName) - $($users[$i].UserPrincipalName)"
        }
        $sel = Read-Host "  Auswahl (Nummer, UPN oder neue Suche per Enter)"
        if ([string]::IsNullOrWhiteSpace($sel)) { continue }
        if ($sel -match '^[0-9]+$') {
            try {
                $idx = [int]$sel
                if ($idx -ge 0 -and $idx -lt $users.Count) {
                    $ownerObj = $users[$idx]
                    break
                }
            } catch {
                Write-Host "  Ungueltige Auswahl." -ForegroundColor Yellow
            }
        } else {
            $directMatch = $users | Where-Object {
                $_.UserPrincipalName -ieq $sel -or $_.Mail -ieq $sel -or $_.DisplayName -ieq $sel
            } | Select-Object -First 1

            if ($directMatch) {
                $ownerObj = $directMatch
                break
            }

            Write-Host "  Kein passender Benutzer fuer diese Eingabe gefunden." -ForegroundColor Yellow
        }
    }
    $ownerUPN = $ownerObj.UserPrincipalName
    Write-Host "  Owner gewaehlt: $($ownerObj.DisplayName) ($ownerUPN)" -ForegroundColor Green
    
    $description = Read-Host "Beschreibung (optional, Enter zum Ueberspringen)"

    Write-Host ""
    Write-Host "Erstelle App-Registrierung..." -ForegroundColor Yellow
    $r = New-EntraAppWithOwner -AppName $appName -OwnerUPN $ownerUPN -TenantId $currentTenantId -Description $description -RedirectUri $redirectUri -TemporaryPassword $temporaryPassword -UserDocumentPath $userDocumentPath
    $allResults.Add($r)
}

# ==============================================================
# Zusammenfassung
# ==============================================================

Write-Host ""
Write-Host "------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Zusammenfassung" -ForegroundColor Cyan
Write-Host "------------------------------------------------------" -ForegroundColor Cyan

$created = @($allResults | Where-Object Status -eq "Erstellt")
$skipped = @($allResults | Where-Object Status -eq "Uebersprungen")
$partial = @($allResults | Where-Object Status -eq "Teilweise")
$failed  = @($allResults | Where-Object Status -eq "Fehler")

Write-Host "  Erstellt     : $($created.Count)" -ForegroundColor Green
if ($partial.Count -gt 0) {
    Write-Host "  Teilweise    : $($partial.Count)" -ForegroundColor Yellow
}
Write-Host "  Uebersprungen: $($skipped.Count)" -ForegroundColor Yellow
Write-Host "  Fehler       : $($failed.Count)"  -ForegroundColor Red
Write-Host ""

if ($allResults.Count -gt 1) {
    $allResults | Format-Table -AutoSize -Property Status, AppName, AppId, Owner, Message
}

# Automatischer Export der Ergebnisse als CSV
$exportCsv = Join-Path (Get-Location) "AppRegistrierung_Ergebnis_${ScriptVersion}_${ScriptBuild}.csv"
($allResults | Select-Object `
    @{Name = 'App-Name'; Expression = { $_.AppName }},
    @{Name = 'App ID'; Expression = { $_.AppId }},
    @{Name = 'Tenant ID'; Expression = { $_.TenantId }},
    @{Name = 'Owner'; Expression = { $_.Owner }},
    @{Name = 'Temporary Password'; Expression = { $_.TemporaryPassword }},
    @{Name = 'User Document'; Expression = { $_.UserDocumentPath }}
) | Export-Csv -Path $exportCsv -NoTypeInformation -Delimiter ";" -Encoding UTF8

Write-Host ""
Write-Host "Skript-Ergebnisse exportiert:" -ForegroundColor Green
Write-Host "  CSV:  $exportCsv"
Write-Host "  Pfad: $([System.IO.Path]::GetFullPath($exportCsv))"
Write-Host ""

Disconnect-MgGraph
Write-Host ""
Write-Host "Fertig." -ForegroundColor Cyan
