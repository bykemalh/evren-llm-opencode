@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================
:: EVREN LLM + OpenCode Kurulum / Kaldirma Scripti (Windows CMD)
::
:: Kullanim:
::   evren-opencode.cmd              (kurulum)
::   evren-opencode.cmd --uninstall  (kaldirma)
::
:: Kurulum:
::   - API key'i gizli alir, User env degiskeni yapar
::   - EVREN kullanim sartlarini gosterir / kabul alir
::   - opencode.jsonc icindeki mevcut ayarlara dokunmadan
::     "evren" provider blogunu ekler / gunceller
::
:: Kaldirma:
::   - opencode.jsonc'den "evren" blogunu cikarir
::   - EVREN_LLM_API_KEY env degiskenini siler
::   - Diger provider / ayarlar korunur
:: ============================================================

set "BASE_URL=https://evren-llmapi.ssyz.org.tr/v1"
set "CONFIG_DIR=%USERPROFILE%\.config\opencode"
set "CONFIG_PATH=%CONFIG_DIR%\opencode.jsonc"
set "KEY_FILE=%CONFIG_DIR%\.evren-key"
set "API_KEY_REF={file:~/.config/opencode/.evren-key}"

:: ── Parametre kontrolü ──────────────────────────────────────

if /I "%~1"=="--uninstall" goto :UNINSTALL

:: ════════════════════════════════════════════════════════════
::  KURULUM
:: ════════════════════════════════════════════════════════════

echo === EVREN LLM + OpenCode Kurulumu ===
echo.

:: ── 1) API key al (gizli) ───────────────────────────────────
for /f "usebackq delims=" %%A in (
  `powershell.exe -NoProfile -Command ^
    "$s=Read-Host 'EVREN LLM API keyinizi girin' -AsSecureString; $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try{([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)).Trim()}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)}"`
) do set "EVREN_LLM_API_KEY=%%A"

if not defined EVREN_LLM_API_KEY (
  echo HATA: API key bos birakilamaz.
  exit /b 1
)

:: Regex'i dogrudan string uzerinde test et (env var'a gerek yok)
powershell.exe -NoProfile -Command ^
  "if ('%EVREN_LLM_API_KEY%' -match '^evren_llm_[A-Za-z0-9_-]+$'){exit 0}else{exit 1}"
if errorlevel 1 (
  echo HATA: API key beklenen evren_llm_... formatinda degil.
  exit /b 1
)

setx EVREN_LLM_API_KEY "%EVREN_LLM_API_KEY%" >nul
if errorlevel 1 (
  echo HATA: EVREN_LLM_API_KEY kullanici ortam degiskenine yazilamadi.
  exit /b 1
)
echo [OK] EVREN_LLM_API_KEY kullanici ortam degiskenine kaydedildi.

:: Anahtari dosya referansi icin .evren-key'e yaz (GUI/IDE dahil her yerden calisir)
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"
powershell.exe -NoProfile -Command ^
  "Set-Content -Path '%KEY_FILE%' -Value '%EVREN_LLM_API_KEY%' -Encoding UTF8NoBOM -NoNewline"
if errorlevel 1 (
  echo HATA: API anahtari .evren-key dosyasina yazilamadi.
  exit /b 1
)
echo [OK] API anahtari .evren-key dosyasina yazildi.

:: ── 2) Terms durumunu kontrol et ────────────────────────────
for /f "usebackq delims=" %%A in (
  `powershell.exe -NoProfile -Command ^
    "$h=@{Authorization='Bearer %EVREN_LLM_API_KEY%'}; try{(Invoke-RestMethod -Uri '%BASE_URL%/terms/status' -Headers $h).current_version}catch{exit 1}"`
) do set "TERMS_VERSION=%%A"

if not defined TERMS_VERSION (
  echo HATA: EVREN terms/status cagrisi basarisiz.
  exit /b 1
)

for /f "usebackq delims=" %%A in (
  `powershell.exe -NoProfile -Command ^
    "$h=@{Authorization='Bearer %EVREN_LLM_API_KEY%'}; try{[string](Invoke-RestMethod -Uri '%BASE_URL%/terms/status' -Headers $h).accepted}catch{exit 1}"`
) do set "TERMS_ACCEPTED=%%A"

if /I not "%TERMS_ACCEPTED%"=="True" (
  echo.
  echo === EVREN Kullanim Sartlari v%TERMS_VERSION% ===
  powershell.exe -NoProfile -Command ^
    "$h=@{Authorization='Bearer %EVREN_LLM_API_KEY%'}; try{(Invoke-RestMethod -Uri '%BASE_URL%/terms/text' -Headers $h).content}catch{Write-Error $_;exit 1}"
  if errorlevel 1 (
    echo HATA: EVREN terms/text cagrisi basarisiz.
    exit /b 1
  )

  echo.
  set /p "TERMS_CONFIRM=Bu kullanim sartlarini kabul ediyor musunuz? Kabul icin EVET yazin: "
  if /I not "!TERMS_CONFIRM!"=="EVET" (
    echo HATA: Kullanim sartlari kabul edilmedi. Kurulum durduruldu.
    exit /b 1
  )

  powershell.exe -NoProfile -Command ^
    "$h=@{Authorization='Bearer %EVREN_LLM_API_KEY%'}; $b=@{version=[int]%TERMS_VERSION%}|ConvertTo-Json -Compress; try{Invoke-RestMethod -Method Post -Uri '%BASE_URL%/terms/accept' -Headers $h -ContentType 'application/json' -Body $b|Out-Null}catch{Write-Error $_;exit 1}"
  if errorlevel 1 (
    echo HATA: EVREN terms/accept cagrisi basarisiz.
    exit /b 1
  )
  echo [OK] EVREN kullanim sartlari v%TERMS_VERSION% kabul edildi.
) else (
  echo [OK] EVREN kullanim sartlari zaten kabul edilmis ^(v%TERMS_VERSION%^).
)

:: ── 3) Kabul durumunu yeniden dogrula ───────────────────────
for /f "usebackq delims=" %%A in (
  `powershell.exe -NoProfile -Command ^
    "$h=@{Authorization='Bearer %EVREN_LLM_API_KEY%'}; try{[string](Invoke-RestMethod -Uri '%BASE_URL%/terms/status' -Headers $h).accepted}catch{exit 1}"`
) do set "VERIFY_ACCEPTED=%%A"

if /I not "%VERIFY_ACCEPTED%"=="True" (
  echo HATA: EVREN kullanim sartlari accepted=true olarak dogrulanamadi.
  exit /b 1
)
echo [OK] Terms kabul durumu dogrulandi.

:: ── 4) opencode.jsonc merge ─────────────────────────────────
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"

:: Varsa yedekle
if exist "%CONFIG_PATH%" (
  for /f "tokens=2 delims==" %%D in ('wmic os get LocalDateTime /value') do set "_DT=%%D"
  set "_DT=!_DT:~0,8!-!_DT:~8,6!"
  copy /y "%CONFIG_PATH%" "%CONFIG_PATH%.bak-!_DT!" >nul
  echo [INFO] Mevcut config yedeklendi: %CONFIG_PATH%.bak-!_DT!
)

:: Merge işlemini PowerShell'e devret
powershell.exe -NoProfile -Command ^
  "$configPath='%CONFIG_PATH%'; $apiKeyRef='%API_KEY_REF%'; $schema='https://opencode.ai/config.json'; " ^
  "$evren=[PSCustomObject]@{ npm='@ai-sdk/openai-compatible'; name='EVREN LLM'; " ^
  "  options=[PSCustomObject]@{ baseURL='https://evren-llmapi.ssyz.org.tr/v1'; apiKey=$apiKeyRef }; " ^
  "  models=[PSCustomObject]@{ 'glm-5.3'=[PSCustomObject]@{name='GLM 5.3'; limit=[PSCustomObject]@{context=200000; output=16384}}; " ^
  "    'deepseek-v4.1-flash'=[PSCustomObject]@{name='DeepSeek V4.1 Flash'; limit=[PSCustomObject]@{context=128000; output=8192}}; " ^
  "    'deepseek-v4-flash'=[PSCustomObject]@{name='DeepSeek V4 Flash'; limit=[PSCustomObject]@{context=128000; output=8192}}; " ^
  "    'qwen3.8-flash-next'=[PSCustomObject]@{name='Qwen 3.8 Flash Next'; limit=[PSCustomObject]@{context=128000; output=8192}}; " ^
  "    'gemma-4-31b'=[PSCustomObject]@{name='Gemma 4 31B'; limit=[PSCustomObject]@{context=128000; output=8192}}; " ^
  "    'qwen3-vl-30b'=[PSCustomObject]@{name='Qwen3 VL 30B'; limit=[PSCustomObject]@{context=128000; output=8192}}; " ^
  "    'auto'=[PSCustomObject]@{name='EVREN Auto'; limit=[PSCustomObject]@{context=128000; output=8192}} } }; " ^
  "if(Test-Path $configPath){ $raw=Get-Content $configPath -Raw -Encoding UTF8; " ^
  "  $stripped=$raw -replace '(?m)^\s*//.*$','' -replace '/\*[\s\S]*?\*/','' -replace ',\s*([}\]])','$1'; " ^
  "  try{ $cfg=$stripped|ConvertFrom-Json }catch{ $cfg=[PSCustomObject]@{} } " ^
  "}else{ $cfg=[PSCustomObject]@{} }; " ^
  "if(-not $cfg.PSObject.Properties['\$schema']){$cfg|Add-Member -NotePropertyName '\$schema' -NotePropertyValue $schema -Force}; " ^
  "if(-not $cfg.PSObject.Properties['model']){$cfg|Add-Member -NotePropertyName 'model' -NotePropertyValue 'evren/glm-5.3' -Force}; " ^
  "if(-not $cfg.PSObject.Properties['small_model']){$cfg|Add-Member -NotePropertyName 'small_model' -NotePropertyValue 'evren/deepseek-v4.1-flash' -Force}; " ^
  "if(-not $cfg.PSObject.Properties['provider']){$cfg|Add-Member -NotePropertyName 'provider' -NotePropertyValue ([PSCustomObject]@{}) -Force}; " ^
  "$cfg.provider|Add-Member -NotePropertyName 'evren' -NotePropertyValue $evren -Force; " ^
  "[System.IO.File]::WriteAllText($configPath,$cfg|ConvertTo-Json -Depth 10,[System.Text.UTF8Encoding]::new($false))"

if errorlevel 1 (
  echo HATA: opencode.jsonc guncellenemedi.
  exit /b 1
)
echo [OK] OpenCode config guncellendi ^(mevcut provider'lar korundu^): %CONFIG_PATH%

:: ── 5) OpenCode doğrulaması ─────────────────────────────────
where opencode >nul 2>nul
if errorlevel 1 (
  echo.
  echo [UYARI] 'opencode' PATH icinde bulunamadi. Config yine de guncellendi.
  echo OpenCode kurulduktan sonra:
  echo   opencode models
  echo   opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."
  echo   Kaldirmak icin: evren-opencode.cmd --uninstall
) else (
  echo.
  echo === opencode models ===
  call opencode models
  if errorlevel 1 (
    echo HATA: opencode models komutu basarisiz oldu.
    exit /b 1
  )
  echo.
  echo [OK] OpenCode EVREN provider'i okuyabiliyor.
  echo.
  echo Test komutu:
  echo   opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."
  echo.
  echo Kaldirmak icin:
  echo   evren-opencode.cmd --uninstall
)

echo.
echo Not: Kalici env degiskeni yeni acilan CMD/PowerShell oturumlarinda otomatik gorunur.
exit /b 0

:: ════════════════════════════════════════════════════════════
::  KALDIRMA (UNINSTALL)
:: ════════════════════════════════════════════════════════════
:UNINSTALL
echo === EVREN LLM OpenCode Kaldirma ===
echo.

:: Varsa yedekle ve evren bloğunu çıkar
if exist "%CONFIG_PATH%" (
  for /f "tokens=2 delims==" %%D in ('wmic os get LocalDateTime /value') do set "_DT=%%D"
  set "_DT=!_DT:~0,8!-!_DT:~8,6!"
  copy /y "%CONFIG_PATH%" "%CONFIG_PATH%.bak-!_DT!" >nul
  echo [INFO] Mevcut config yedeklendi: %CONFIG_PATH%.bak-!_DT!

  powershell.exe -NoProfile -Command ^
    "$p='%CONFIG_PATH%'; $raw=Get-Content $p -Raw -Encoding UTF8; " ^
    "$stripped=$raw -replace '(?m)^\s*//.*$','' -replace '/\*[\s\S]*?\*/','' -replace ',\s*([}\]])','$1'; " ^
    "try{ $cfg=$stripped|ConvertFrom-Json }catch{ Write-Host '[INFO] JSON parse hatasi, degisiklik yapilmadi.';exit 0 }; " ^
    "$removed=$false; " ^
    "if($cfg.provider -and $cfg.provider.PSObject.Properties['evren']){ $cfg.provider.PSObject.Properties.Remove('evren'); $removed=$true; " ^
    "  if(($cfg.provider.PSObject.Properties|Measure-Object).Count -eq 0){ $cfg.PSObject.Properties.Remove('provider') } }; " ^
    "if($cfg.PSObject.Properties['model'] -and $cfg.model -like 'evren/*'){ $cfg.PSObject.Properties.Remove('model'); Write-Host '[INFO] Varsayilan model evren/... kaldirildi.' }; " ^
    "if($cfg.PSObject.Properties['small_model'] -and $cfg.small_model -like 'evren/*'){ $cfg.PSObject.Properties.Remove('small_model'); Write-Host '[INFO] small_model evren/... kaldirildi.' }; " ^
    "if($removed){ [System.IO.File]::WriteAllText($p,$cfg|ConvertTo-Json -Depth 10,[System.Text.UTF8Encoding]::new($false)); Write-Host '[OK] evren provider blogu kaldirildi.' " ^
    "}else{ Write-Host '[INFO] evren blogu bulunamadi; config degistirilmedi.' }"

  if errorlevel 1 (
    echo HATA: Config guncellenirken hata olustu.
    exit /b 1
  )
) else (
  echo [INFO] opencode.jsonc bulunamadi; config degisikligi gerekmedi.
)

:: EVREN_LLM_API_KEY'i sil
powershell.exe -NoProfile -Command ^
  "$v=[Environment]::GetEnvironmentVariable('EVREN_LLM_API_KEY','User'); " ^
  "if($null -ne $v){ [Environment]::SetEnvironmentVariable('EVREN_LLM_API_KEY',$null,'User'); Write-Host '[OK] EVREN_LLM_API_KEY kullanici ortam degiskeninden kaldirildi.' " ^
  "}else{ Write-Host '[INFO] EVREN_LLM_API_KEY zaten tanimli degil.' }"

:: .evren-key dosyasini sil
if exist "%KEY_FILE%" (
  del "%KEY_FILE%"
  echo [OK] .evren-key dosyasi silindi.
) else (
  echo [INFO] .evren-key dosyasi zaten yok.
)

echo.
echo [OK] Kaldirma tamamlandi. Diger provider/ayarlar korundu.
exit /b 0
