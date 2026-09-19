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

.EXAMPLE
    .\evren-opencode.ps1
    .\evren-opencode.ps1 --uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
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

# ── EVREN provider bloğu ─────────────────────────────────────────────────────

# NOT: limit degerleri opencode'un varsayilan 200k context / 32k output
# faraziyesini ezer. 32k output bircok API'de "max_tokens too large" veya
# gereksiz rate-limit baskisi yaratir; muhafazakar degerler kullanilir.
$EvrenProvider = [PSCustomObject]@{
    npm     = "@ai-sdk/openai-compatible"
    name    = "EVREN LLM"
    options = [PSCustomObject]@{
        baseURL = "https://evren-llmapi.ssyz.org.tr/v1"
        apiKey  = $ApiKeyRef
    }
    models  = [PSCustomObject]@{
        "glm-5.3"           = [PSCustomObject]@{ name = "GLM 5.3";            limit = [PSCustomObject]@{ context = 200000; output = 16384 } }
        "deepseek-v4-flash" = [PSCustomObject]@{ name = "DeepSeek V4 Flash";  limit = [PSCustomObject]@{ context = 128000; output = 8192 } }
        "qwen3.8-flash-next"= [PSCustomObject]@{ name = "Qwen 3.8 Flash Next";limit = [PSCustomObject]@{ context = 128000; output = 8192 } }
        "gemma-4-31b"       = [PSCustomObject]@{ name = "Gemma 4 31B";        limit = [PSCustomObject]@{ context = 128000; output = 8192 } }
        "qwen3-vl-30b"      = [PSCustomObject]@{ name = "Qwen3 VL 30B";       limit = [PSCustomObject]@{ context = 128000; output = 8192 } }
        "auto"              = [PSCustomObject]@{ name = "EVREN Auto";         limit = [PSCustomObject]@{ context = 128000; output = 8192 } }
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

# ── 4) opencode.jsonc'ye merge et ────────────────────────────────────────────

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Backup-Config | Out-Null

$cfg = Read-Config

# $schema ekle (yoksa)
if (-not $cfg.PSObject.Properties["`$schema"]) {
    $cfg | Add-Member -NotePropertyName "`$schema" -NotePropertyValue "https://opencode.ai/config.json" -Force
}

# model: sadece daha önce set edilmemişse evren varsayılanını yaz
if (-not $cfg.PSObject.Properties["model"]) {
    $cfg | Add-Member -NotePropertyName "model" -NotePropertyValue "evren/glm-5.3" -Force
}

# small_model: hafif isler (baslik vb.) icin flash model, rate-limit baskisini azaltir
if (-not $cfg.PSObject.Properties["small_model"]) {
    $cfg | Add-Member -NotePropertyName "small_model" -NotePropertyValue "evren/deepseek-v4-flash" -Force
}

# provider objesini oluştur (yoksa)
if (-not $cfg.PSObject.Properties["provider"]) {
    $cfg | Add-Member -NotePropertyName "provider" -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# provider.evren bloğunu ekle/güncelle
$cfg.provider | Add-Member -NotePropertyName "evren" -NotePropertyValue $EvrenProvider -Force

Write-Config -Cfg $cfg
Ok "openCode config guncellendi (mevcut provider'lar korundu): $ConfigPath"

# ── 5) OpenCode doğrulaması ───────────────────────────────────────────────────

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
