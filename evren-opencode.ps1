#Requires -Version 5.1
<#
.SYNOPSIS
    EVREN LLM provider'ini OpenCode'a kurar veya kaldirır.

.DESCRIPTION
    Varsayılan mod (kurulum):
      - API key'i güvenli alır, User env variable olarak kaydeder
      - EVREN kullanım şartlarını gösterir ve kabul alır
      - opencode.jsonc içindeki mevcut provider'lara dokunmadan "evren" bloğunu ekler/günceller

    Kaldırma modu (--uninstall):
      - opencode.jsonc'den "evren" provider bloğunu siler
      - EVREN_LLM_API_KEY environment variable'ını temizler
      - Diğer provider/ayarlar korunur

.PARAMETER Uninstall
    Belirtilirse kurulum değil kaldırma işlemi yapılır.

.PARAMETER SyncModels
    Belirtilirse kurulum yapılmaz; kayıtlı anahtar (.evren-key) ile
    sadece model listesi API'den çekilip config güncellenir.

.EXAMPLE
    .\evren-opencode.ps1
    .\evren-opencode.ps1 -SyncModels
    .\evren-opencode.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$SyncModels
)

$ErrorActionPreference = "Stop"

$BaseUrl   = "https://evren-llmapi.ssyz.org.tr/v1"
$ConfigDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".config\opencode"
$ConfigPath = Join-Path $ConfigDir "opencode.jsonc"
$KeyFile = Join-Path $ConfigDir ".evren-key"
# Shell'den bagimsiz calismasi icin config bu dosya referansini kullanir
$ApiKeyRef = "{file:~/.config/opencode/.evren-key}"

# ── Yardımcı fonksiyonlar ────────────────────────────────────────────────────

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "HATA: $Message" -ForegroundColor Red
    exit 1
}

function Ok([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor DarkYellow
}

function Warn([string]$Message) {
    Write-Host "[UYARI] $Message" -ForegroundColor Yellow
}

# opencode.jsonc'yi okuyup PSObject döndürür; yoksa boş obje döner.
function Read-Config {
    if (-not (Test-Path $ConfigPath)) {
        return [PSCustomObject]@{}
    }
    $raw = Get-Content $ConfigPath -Raw -Encoding UTF8
    # JSONC yorumlarını temizle (// ve /* */ )
    $stripped = $raw -replace '(?m)^\s*//.*$','' `
                     -replace '/\*[\s\S]*?\*/','`
' `
                     -replace ',\s*([}\]])', '$1'
    try {
        return ($stripped | ConvertFrom-Json)
    }
    catch {
        Warn "Mevcut opencode.jsonc parse edilemedi; sifirdan olusturulacak. (Eski dosya yedeklendi)"
        return [PSCustomObject]@{}
    }
}

# PSObject'i düzgün girintili UTF-8 JSON olarak yazar (BOM yok).
function Write-Config([PSCustomObject]$Cfg) {
    $json = $Cfg | ConvertTo-Json -Depth 10
    # $schema en üste gelsin (kosmetik)
    [System.IO.File]::WriteAllText(
        $ConfigPath,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# Bir PSObject üzerinde dot-path ile iç içe property set eder.
# Set-NestedProperty $obj "provider.evren" $value
function Set-NestedProperty {
    param(
        [PSCustomObject]$Root,
        [string]$Path,
        $Value
    )
    $parts = $Path -split '\.',2
    if ($parts.Count -eq 1) {
        $Root | Add-Member -NotePropertyName $parts[0] -NotePropertyValue $Value -Force
    } else {
        if ($null -eq $Root.($parts[0])) {
            $Root | Add-Member -NotePropertyName $parts[0] -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        Set-NestedProperty -Root $Root.($parts[0]) -Path $parts[1] -Value $Value
    }
}

# PSObject'ten bir property'yi siler; yoksa sessizce geçer.
function Remove-Property {
    param([PSCustomObject]$Obj, [string]$Name)
    if ($Obj.PSObject.Properties[$Name]) {
        $Obj.PSObject.Properties.Remove($Name)
    }
}

# Config'i yedekler ve yolunu döndürür.
function Backup-Config {
    if (Test-Path $ConfigPath) {
        $backup = "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $ConfigPath $backup
        Info "Mevcut config yedeklendi: $backup"
        return $backup
    }
    return $null
}

# ── Model listesi: API'den otomatik cekme ────────────────────────────────────

# Son bilinen liste (/v1/models yanit seklinde; degerler gercek API degerleridir).
# API erisilemezse kurulum bu listeyle tamamlanir (uyariyla).
$FallbackModelsJson = '{"object":"list","data":[{"id":"glm-5.3","task":"chat","context_length":524288,"default_max_output_tokens":16384},{"id":"deepseek-v4.1-flash","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"deepseek-v4-flash","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"qwen3.8-flash-next","task":"chat","context_length":262144,"default_max_output_tokens":16384},{"id":"gemma-4-31b","task":"chat","context_length":262144,"default_max_output_tokens":16384},{"id":"qwen3-vl-30b","task":"vision_chat","context_length":262144,"default_max_output_tokens":16384},{"id":"mimo-v2.6-pro","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"auto","task":"chat","context_length":32768,"default_max_output_tokens":16384}]}'

$KnownModelNames = @{
    "glm-5.3"             = "GLM 5.3"
    "deepseek-v4.1-flash" = "DeepSeek V4.1 Flash"
    "deepseek-v4-flash"   = "DeepSeek V4 Flash"
    "qwen3.8-flash-next"  = "Qwen 3.8 Flash Next"
    "gemma-4-31b"         = "Gemma 4 31B"
    "qwen3-vl-30b"        = "Qwen3 VL 30B"
    "mimo-v2.6-pro"       = "MiMo V2.6 Pro"
    "auto"                = "EVREN Auto"
}

function Get-PrettyModelName {
    param([string]$Id)
    if ($KnownModelNames.ContainsKey($Id)) {
        return $KnownModelNames[$Id]
    }
    $acronyms = @{
        glm = "GLM"; qwen = "Qwen"; gemma = "Gemma"; deepseek = "DeepSeek"
        mimo = "MiMo"; vl = "VL"; ocr = "OCR"; asr = "ASR"
    }
    $words = foreach ($tok in ($Id -split '-')) {
        $low = $tok.ToLowerInvariant()
        if ($acronyms.ContainsKey($low)) {
            $acronyms[$low]
        }
        elseif ($low -match '^[0-9]+[a-z]*$') {
            $tok.ToUpperInvariant()
        }
        elseif ($tok.Length -gt 0) {
            $tok.Substring(0, 1).ToUpperInvariant() + $tok.Substring(1)
        }
        else {
            $tok
        }
    }
    return ($words -join ' ')
}

# API yanitindan (PSObject) opencode "models" haritasi uretir.
# Sadece task=chat / vision_chat alinir; limit'ler API degerlerinden gelir.
function ConvertTo-ModelsMap {
    param($Payload)
    $map = [PSCustomObject]@{}
    foreach ($m in $Payload.data) {
        if ($null -eq $m) { continue }
        $id = $m.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $task = if ($m.PSObject.Properties['task'] -and $m.task) { $m.task } else { 'chat' }
        if ($task -notin @('chat', 'vision_chat')) { continue }
        $ctx = if ($m.context_length) { [int]$m.context_length } else { 128000 }
        $out = if ($m.default_max_output_tokens) { [int]$m.default_max_output_tokens } else { 8192 }
        $map | Add-Member -NotePropertyName $id -NotePropertyValue (
            [PSCustomObject]@{
                name  = (Get-PrettyModelName $id)
                limit = [PSCustomObject]@{ context = $ctx; output = $out }
            }) -Force
    }
    if (($map.PSObject.Properties | Measure-Object).Count -eq 0) {
        throw "API sohbet modeli dondurmedi."
    }
    return $map
}

# Config'e "evren" provider blogunu tam senkronla yazar:
# yeni modeller eklenir, limitler tazelenir, API'den kalkanlar silinir.
# model/small_model yoksa veya artik listede degilse guvenli degere alinir.
function Merge-EvrenConfig {
    param([PSCustomObject]$Cfg, $ModelsMap)
    if (-not $Cfg.PSObject.Properties["`$schema"]) {
        $Cfg | Add-Member -NotePropertyName "`$schema" -NotePropertyValue "https://opencode.ai/config.json" -Force
    }
    if (-not $Cfg.PSObject.Properties["provider"]) {
        $Cfg | Add-Member -NotePropertyName "provider" -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $provider = [PSCustomObject]@{
        npm     = "@ai-sdk/openai-compatible"
        name    = "EVREN LLM"
        options = [PSCustomObject]@{
            baseURL = $BaseUrl
            apiKey  = $ApiKeyRef
        }
        models  = $ModelsMap
    }
    $Cfg.provider | Add-Member -NotePropertyName "evren" -NotePropertyValue $provider -Force

    $ids = @($ModelsMap.PSObject.Properties.Name)
    $cur = $Cfg.PSObject.Properties["model"]
    if ((-not $cur) -or (($Cfg.model -like "evren/*") -and ($ids -notcontains ($Cfg.model -replace '^evren/', '')))) {
        if ($ids -contains "glm-5.3") { $def = "evren/glm-5.3" }
        elseif ($ids -contains "auto") { $def = "evren/auto" }
        else { $def = "evren/$($ids[0])" }
        $Cfg | Add-Member -NotePropertyName "model" -NotePropertyValue $def -Force
    }
    $curSmall = $Cfg.PSObject.Properties["small_model"]
    if ((-not $curSmall) -or (($Cfg.small_model -like "evren/*") -and ($ids -notcontains ($Cfg.small_model -replace '^evren/', '')))) {
        if ($ids -contains "deepseek-v4.1-flash") {
            $small = "evren/deepseek-v4.1-flash"
        }
        else {
            $min = $ModelsMap.PSObject.Properties | Sort-Object { $_.Value.limit.context } | Select-Object -First 1
            $small = "evren/$($min.Name)"
        }
        $Cfg | Add-Member -NotePropertyName "small_model" -NotePropertyValue $small -Force
    }
}

# ════════════════════════════════════════════════════════════════════════════
# UNINSTALL MODU
# ════════════════════════════════════════════════════════════════════════════

if ($Uninstall) {
    Write-Host "=== EVREN LLM OpenCode Kaldirma ===" -ForegroundColor Cyan

    # 1) Config'den evren bloğunu kaldır
    if (Test-Path $ConfigPath) {
        Backup-Config | Out-Null
        $cfg = Read-Config

        $removed = $false
        if ($cfg.provider -and $cfg.provider.PSObject.Properties["evren"]) {
            Remove-Property -Obj $cfg.provider -Name "evren"
            $removed = $true

            # provider objesi artık boşsa onu da kaldır
            if (($cfg.provider.PSObject.Properties | Measure-Object).Count -eq 0) {
                Remove-Property -Obj $cfg -Name "provider"
            }
        }

        # model "evren/..." ise temizle
        if ($cfg.PSObject.Properties["model"] -and ($cfg.model -like "evren/*")) {
            Remove-Property -Obj $cfg -Name "model"
            Info "Varsayilan model 'evren/...' kaldirildi."
        }

        # small_model "evren/..." ise temizle
        if ($cfg.PSObject.Properties["small_model"] -and ($cfg.small_model -like "evren/*")) {
            Remove-Property -Obj $cfg -Name "small_model"
            Info "small_model 'evren/...' kaldirildi."
        }

        if ($removed) {
            Write-Config -Cfg $cfg
            Ok "opencode.jsonc'den 'evren' provider blogu kaldirildi: $ConfigPath"
        } else {
            Info "opencode.jsonc'de 'evren' provider blogu bulunamadi; degisiklik yapilmadi."
        }
    } else {
        Info "opencode.jsonc bulunamadi; config degisikligi gerekmedi."
    }

    # 2) EVREN_LLM_API_KEY env variable'ını sil
    $existing = [Environment]::GetEnvironmentVariable("EVREN_LLM_API_KEY", "User")
    if ($null -ne $existing) {
        [Environment]::SetEnvironmentVariable("EVREN_LLM_API_KEY", $null, "User")
        Remove-Item Env:EVREN_LLM_API_KEY -ErrorAction SilentlyContinue
        Ok "EVREN_LLM_API_KEY kullanici ortam degiskeninden kaldirildi."
    } else {
        Info "EVREN_LLM_API_KEY zaten tanimli degil."
    }

    # 3) Anahtar dosyasini sil
    if (Test-Path $KeyFile) {
        Remove-Item $KeyFile -Force
        Ok ".evren-key dosyasi silindi ($KeyFile)."
    } else {
        Info ".evren-key dosyasi zaten yok."
    }

    Write-Host ""
    Ok "Kaldirma tamamlandi. Diger provider/ayarlar korundu."
    exit 0
}

# ════════════════════════════════════════════════════════════════════════════
# SYNC-MODELS MODU (anahtar sormaz, terms adimini atlar)
# ════════════════════════════════════════════════════════════════════════════

if ($SyncModels) {
    Write-Host "=== EVREN LLM Model Listesi Guncellemesi ===" -ForegroundColor Cyan

    # Kayitli anahtari kullan (.evren-key yoksa env'e bak)
    $syncKey = $null
    if (Test-Path $KeyFile) {
        $syncKey = ((Get-Content $KeyFile -Raw -Encoding UTF8) | Out-String).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($syncKey) -and $env:EVREN_LLM_API_KEY) {
        $syncKey = $env:EVREN_LLM_API_KEY.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($syncKey)) {
        Fail "Kayitli API anahtari bulunamadi ($KeyFile yok). Once kurulumu calistirin."
    }

    try {
        $payload = Invoke-RestMethod -Method Get -Uri "$BaseUrl/models" -Headers @{ Authorization = "Bearer $syncKey" }
        $modelsMap = ConvertTo-ModelsMap $payload
        Ok "Model listesi API'den alindi."
    }
    catch {
        Fail "Model listesi alinamadi: $($_.Exception.Message)"
    }

    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    Backup-Config | Out-Null
    $cfg = Read-Config
    Merge-EvrenConfig -Cfg $cfg -ModelsMap $modelsMap
    Write-Config -Cfg $cfg
    Ok "Model listesi API ile senkronize edildi (mevcut provider'lar korundu): $ConfigPath"
    exit 0
}

# ════════════════════════════════════════════════════════════════════════════
# KURULUM MODU
# ════════════════════════════════════════════════════════════════════════════

Write-Host "=== EVREN LLM + OpenCode Kurulumu ===" -ForegroundColor Cyan

# ── 1) API key al ve doğrula ─────────────────────────────────────────────────

$secureKey = Read-Host "EVREN LLM API key'inizi girin" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try {
    $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

# Yapistirmadan gelebilecek bas-son bosluklari temizle
$ApiKey = $ApiKey.Trim()

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Fail "API key bos birakilamaz."
}

# Regex'i doğrudan $ApiKey string'i üzerinde çalıştır (env var'a gerek yok)
if ($ApiKey -notmatch '^evren_llm_[A-Za-z0-9_-]+$') {
    Fail "API key beklenen 'evren_llm_...' formatinda degil."
}

[Environment]::SetEnvironmentVariable("EVREN_LLM_API_KEY", $ApiKey, "User")
$env:EVREN_LLM_API_KEY = $ApiKey
Ok "EVREN_LLM_API_KEY kullanici ortam degiskenine kaydedildi."

# Anahtari dosya referansi icin .evren-key'e yaz (GUI/IDE dahil her yerden calisir)
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Set-Content -Path $KeyFile -Value $ApiKey -Encoding UTF8NoBOM -NoNewline
Ok "API anahtari $KeyFile dosyasina yazildi."

$Headers = @{ Authorization = "Bearer $ApiKey" }

# ── 2) Terms durumunu kontrol et ─────────────────────────────────────────────

try {
    $status = Invoke-RestMethod -Method Get -Uri "$BaseUrl/terms/status" -Headers $Headers
}
catch {
    Fail "EVREN terms/status cagrisi basarisiz: $($_.Exception.Message)"
}

$termsVersion = $status.current_version

if (-not $status.accepted) {
    try {
        $terms = Invoke-RestMethod -Method Get -Uri "$BaseUrl/terms/text" -Headers $Headers
    }
    catch {
        Fail "EVREN terms/text cagrisi basarisiz: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "=== EVREN Kullanim Sartlari (v$termsVersion) ===" -ForegroundColor Yellow
    Write-Host $terms.content
    Write-Host ""

    $confirmation = Read-Host "Bu kullanim sartlarini kabul ediyor musunuz? Kabul icin EVET yazin"
    if ($confirmation.Trim().ToUpperInvariant() -ne "EVET") {
        Fail "Kullanim sartlari kabul edilmedi. Kurulum durduruldu."
    }

    $body = @{ version = [int]$termsVersion } | ConvertTo-Json -Compress
    try {
        $accept = Invoke-RestMethod `
            -Method Post `
            -Uri "$BaseUrl/terms/accept" `
            -Headers $Headers `
            -ContentType "application/json" `
            -Body $body
        Ok "EVREN kullanim sartlari v$($accept.accepted_version) kabul edildi."
    }
    catch {
        Fail "EVREN terms/accept cagrisi basarisiz: $($_.Exception.Message)"
    }
}
else {
    Ok "EVREN kullanim sartlari zaten kabul edilmis (v$termsVersion)."
}

# ── 3) Kabul durumunu yeniden doğrula ────────────────────────────────────────

try {
    $verify = Invoke-RestMethod -Method Get -Uri "$BaseUrl/terms/status" -Headers $Headers
}
catch {
    Fail "Kabul dogrulamasi basarisiz: $($_.Exception.Message)"
}

if (-not $verify.accepted) {
    Fail "EVREN kullanim sartlari accepted=true olarak dogrulanamadi."
}
Ok "Terms kabul durumu dogrulandi."

# ── 4) Model listesini API'den cek ───────────────────────────────────────────

try {
    $modelsPayload = Invoke-RestMethod -Method Get -Uri "$BaseUrl/models" -Headers $Headers
    $modelsMap = ConvertTo-ModelsMap $modelsPayload
    Ok "Model listesi API'den alindi."
}
catch {
    Warn "Model listesi API'den alinamadi ($($_.Exception.Message)); son bilinen liste kullanilacak."
    $modelsMap = ConvertTo-ModelsMap ($FallbackModelsJson | ConvertFrom-Json)
}

# ── 5) opencode.jsonc'ye merge et ────────────────────────────────────────────

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Backup-Config | Out-Null

$cfg = Read-Config
Merge-EvrenConfig -Cfg $cfg -ModelsMap $modelsMap

Write-Config -Cfg $cfg
Ok "openCode config guncellendi (mevcut provider'lar korundu): $ConfigPath"

# ── 6) OpenCode doğrulaması ───────────────────────────────────────────────────

if (Get-Command opencode -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "=== opencode models ===" -ForegroundColor Cyan
    & opencode models
    if ($LASTEXITCODE -ne 0) {
        Fail "opencode models komutu basarisiz oldu."
    }

    Write-Host ""
    Ok "OpenCode EVREN provider'i okuyabiliyor."
    Write-Host ""
    Write-Host "Test komutu:" -ForegroundColor Cyan
    Write-Host 'opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."'
    Write-Host ""
    Write-Host "Kaldirmak icin:" -ForegroundColor Cyan
    Write-Host ".\evren-opencode.ps1 --uninstall"
}
else {
    Write-Host ""
    Warn "'opencode' PATH icinde bulunamadi. Config yine de guncellendi."
    Write-Host "OpenCode kurulduktan sonra su komutlari calistirin:"
    Write-Host "  opencode models"
    Write-Host '  opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."'
    Write-Host ""
    Write-Host "Kaldirmak icin: .\evren-opencode.ps1 --uninstall"
}

Write-Host ""
Write-Host "Not: Kalici environment variable yeni acilan terminal oturumlarinda otomatik yuklenir." -ForegroundColor DarkGray
