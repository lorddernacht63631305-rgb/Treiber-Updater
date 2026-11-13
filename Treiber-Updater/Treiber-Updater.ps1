#Requires -Version 5.1
<#
    Treiber-Updater
    ----------------
    Sucht über die offizielle Windows-Update-Schnittstelle nach neuen Treibern,
    zeigt sie an und installiert sie auf Wunsch.

    Start:  Doppelklick auf "Treiber-Updater starten.bat"
    Optional per PowerShell:
        .\Treiber-Updater.ps1              -> anzeigen und nachfragen
        .\Treiber-Updater.ps1 -NurAnzeigen -> nur auflisten, nichts installieren
        .\Treiber-Updater.ps1 -Automatisch -> ohne Nachfrage installieren
#>
param(
    [switch]$NurAnzeigen,
    [switch]$Automatisch
)

# --- Administratorrechte sicherstellen -------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Starte mit Administratorrechten neu ..." -ForegroundColor Yellow
    $argListe = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($NurAnzeigen) { $argListe += " -NurAnzeigen" }
    if ($Automatisch) { $argListe += " -Automatisch" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argListe
    exit
}

$Host.UI.RawUI.WindowTitle = "Treiber-Updater"
$logDatei = Join-Path $PSScriptRoot ("Treiber-Update-Log_{0:yyyy-MM-dd_HH-mm}.txt" -f (Get-Date))
Start-Transcript -Path $logDatei -Append | Out-Null

function Beenden {
    Stop-Transcript | Out-Null
    Write-Host ""
    Write-Host "Protokoll gespeichert unter: $logDatei" -ForegroundColor DarkGray
    Read-Host "Enter drücken zum Beenden"
    exit
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "            T R E I B E R - U P D A T E R      " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# --- Nach Treiber-Updates suchen -------------------------------------------
Write-Host "Suche nach neuen Treibern über Windows Update (kann 1-3 Minuten dauern) ..." -ForegroundColor Yellow
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = "Treiber-Updater"
    $searcher = $session.CreateUpdateSearcher()
    $ergebnis = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
}
catch {
    Write-Host "Fehler bei der Suche: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Prüfe, ob du mit dem Internet verbunden bist und der Dienst 'Windows Update' läuft." -ForegroundColor Red
    Beenden
}

$updates = @()
foreach ($u in $ergebnis.Updates) { $updates += $u }

if ($updates.Count -eq 0) {
    Write-Host ""
    Write-Host "Alles aktuell - Windows Update hat keine neuen Treiber gefunden." -ForegroundColor Green
    Beenden
}

Write-Host ""
Write-Host "Gefundene Treiber-Updates: $($updates.Count)" -ForegroundColor Green
Write-Host ""
$i = 1
foreach ($u in $updates) {
    $datum = ""
    try { if ($u.DriverVerDate) { $datum = ([datetime]$u.DriverVerDate).ToString("dd.MM.yyyy") } } catch {}
    Write-Host ("[{0}] {1}" -f $i, $u.Title) -ForegroundColor White
    Write-Host ("     Hersteller: {0}   Klasse: {1}   Version vom: {2}" -f $u.DriverManufacturer, $u.DriverClass, $datum) -ForegroundColor DarkGray
    $i++
}
Write-Host ""

if ($NurAnzeigen) {
    Write-Host "Modus 'Nur anzeigen' - es wird nichts installiert." -ForegroundColor Yellow
    Beenden
}

# --- Auswahl ---------------------------------------------------------------
$auswahl = $updates
if (-not $Automatisch) {
    Write-Host "Was möchtest du installieren?"
    Write-Host "  A        = alle"
    Write-Host "  1,3,4    = nur bestimmte Nummern"
    Write-Host "  N        = abbrechen"
    $eingabe = (Read-Host "Auswahl").Trim()

    if ($eingabe -match '^[Nn]') { Write-Host "Abgebrochen." -ForegroundColor Yellow; Beenden }
    if ($eingabe -notmatch '^[Aa]') {
        $auswahl = @()
        foreach ($teil in ($eingabe -split '[,; ]+')) {
            $n = 0
            if ([int]::TryParse($teil, [ref]$n) -and $n -ge 1 -and $n -le $updates.Count) {
                $auswahl += $updates[$n - 1]
            }
        }
        if ($auswahl.Count -eq 0) { Write-Host "Keine gültige Auswahl." -ForegroundColor Red; Beenden }
    }
}

# --- Wiederherstellungspunkt -----------------------------------------------
Write-Host ""
Write-Host "Erstelle Wiederherstellungspunkt (Sicherheitsnetz, falls ein Treiber Probleme macht) ..." -ForegroundColor Yellow
try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description "Vor Treiber-Update" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    Write-Host "Wiederherstellungspunkt erstellt." -ForegroundColor Green
}
catch {
    Write-Host "Hinweis: Kein Wiederherstellungspunkt möglich ($($_.Exception.Message))." -ForegroundColor DarkYellow
    Write-Host "(Windows erlaubt nur einen pro 24 Stunden, oder der Computerschutz ist aus.)" -ForegroundColor DarkYellow
    if (-not $Automatisch) {
        $weiter = Read-Host "Trotzdem fortfahren? (J/N)"
        if ($weiter -notmatch '^[Jj]') { Write-Host "Abgebrochen." -ForegroundColor Yellow; Beenden }
    }
}

# --- Herunterladen ---------------------------------------------------------
$sammlung = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($u in $auswahl) {
    if (-not $u.EulaAccepted) { $u.AcceptEula() }
    [void]$sammlung.Add($u)
}

Write-Host ""
Write-Host "Lade $($sammlung.Count) Treiber herunter ..." -ForegroundColor Yellow
try {
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $sammlung
    [void]$downloader.Download()
}
catch {
    Write-Host "Fehler beim Herunterladen: $($_.Exception.Message)" -ForegroundColor Red
    Beenden
}

# --- Installieren ----------------------------------------------------------
Write-Host "Installiere Treiber (der Bildschirm kann kurz flackern) ..." -ForegroundColor Yellow
try {
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $sammlung
    $installErgebnis = $installer.Install()
}
catch {
    Write-Host "Fehler bei der Installation: $($_.Exception.Message)" -ForegroundColor Red
    Beenden
}

$statusText = @{ 0 = "Nicht gestartet"; 1 = "Läuft"; 2 = "Erfolgreich"; 3 = "Erfolgreich mit Fehlern"; 4 = "Fehlgeschlagen"; 5 = "Abgebrochen" }
Write-Host ""
Write-Host "Ergebnis:" -ForegroundColor Cyan
for ($k = 0; $k -lt $sammlung.Count; $k++) {
    $code  = $installErgebnis.GetUpdateResult($k).ResultCode
    $farbe = if ($code -eq 2) { "Green" } elseif ($code -eq 3) { "Yellow" } else { "Red" }
    Write-Host ("  {0}: {1}" -f $statusText[[int]$code], $sammlung.Item($k).Title) -ForegroundColor $farbe
}

if ($installErgebnis.RebootRequired) {
    Write-Host ""
    Write-Host "Ein Neustart ist nötig, damit die Treiber aktiv werden." -ForegroundColor Yellow
    $neustart = if ($Automatisch) { "N" } else { Read-Host "Jetzt neu starten? (J/N)" }
    if ($neustart -match '^[Jj]') {
        Stop-Transcript | Out-Null
        Restart-Computer -Force
        exit
    }
}

Write-Host ""
Write-Host "Fertig!" -ForegroundColor Green
Beenden
