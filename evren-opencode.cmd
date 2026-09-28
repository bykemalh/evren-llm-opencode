@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================
:: EVREN LLM + OpenCode Kurulum / Kaldirma Scripti (Windows CMD)
::
:: Kullanim:
::   evren-opencode.cmd                (kurulum)
::   evren-opencode.cmd --sync-models  (sadece model listesini tazele)
::   evren-opencode.cmd --uninstall    (kaldirma)
::
:: Kurulum:
::   - API key'i gizli alir, User env degiskeni yapar
::   - EVREN kullanim sartlarini gosterir / kabul alir
::   - Model listesini API'den (/v1/models) otomatik ceker ve
::     opencode.jsonc icindeki mevcut ayarlara dokunmadan
::     "evren" provider blogunu ekler / gunceller (tam senkron)
::
:: --sync-models:
::   - Kayitli anahtari (.evren-key) kullanir, anahtar sormaz
::   - Terms adimini atlar; sadece model listesini API'den cekip
::     config'deki "evren" provider blogunu gunceller
::
:: Model senkronu (kurulum + --sync-models):
::   - Sadece sohbet modelleri yazilir (task: chat / vision_chat);
::     embedding/rerank/ocr/ses modelleri elenir
::   - limit.context API'deki context_length'ten, limit.output
::     default_max_output_tokens'tan alinir (null ise 8192)
::   - API'de olmayan modeller config'den silinir (tam senkron);
::     gecersiz kalan model/small_model guvenli degere alinir
::   - API'ye erisilemezse kurulum son bilinen listeyle tamamlanir (uyariyla)
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
if /I "%~1"=="--sync-models" goto :SYNCMODELS
if /I "%~1"=="--update-models" goto :SYNCMODELS
if not "%~1"=="" (
  echo HATA: Bilinmeyen parametre. Desteklenenler: --sync-models, --uninstall
  exit /b 1
)

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

:: ── 4) Model listesini API'den cek + opencode.jsonc merge ───
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"

:: Varsa yedekle
if exist "%CONFIG_PATH%" (
  for /f "tokens=2 delims==" %%D in ('wmic os get LocalDateTime /value') do set "_DT=%%D"
  set "_DT=!_DT:~0,8!-!_DT:~8,6!"
  copy /y "%CONFIG_PATH%" "%CONFIG_PATH%.bak-!_DT!" >nul
  echo [INFO] Mevcut config yedeklendi: %CONFIG_PATH%.bak-!_DT!
)

set "ALLOW_FALLBACK=1"
call :FETCH_MODELS
if errorlevel 1 (
  exit /b 1
)

call :MERGE_CONFIG
if errorlevel 1 (
  exit /b 1
)
del "%MODELS_TMP%" 2>nul

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

:: ════════════════════════════════════════════════════════════
::  MODEL SENKRONU (anahtar sormaz, terms adimini atlar)
:: ════════════════════════════════════════════════════════════
:SYNCMODELS
echo === EVREN LLM Model Listesi Guncellemesi ===
echo.

if not exist "%KEY_FILE%" (
  echo HATA: Kayitli API anahtari bulunamadi. Once kurulumu calistirin.
  exit /b 1
)
for /f "usebackq delims=" %%A in (
  `powershell.exe -NoProfile -Command "(Get-Content '%KEY_FILE%' -Raw -Encoding UTF8).Trim()"`
) do set "EVREN_LLM_API_KEY=%%A"

if not defined EVREN_LLM_API_KEY (
  echo HATA: Kayitli API anahtari okunamadi.
  exit /b 1
)

if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"
if exist "%CONFIG_PATH%" (
  for /f "tokens=2 delims==" %%D in ('wmic os get LocalDateTime /value') do set "_DT=%%D"
  set "_DT=!_DT:~0,8!-!_DT:~8,6!"
  copy /y "%CONFIG_PATH%" "%CONFIG_PATH%.bak-!_DT!" >nul
  echo [INFO] Mevcut config yedeklendi: %CONFIG_PATH%.bak-!_DT!
)

set "ALLOW_FALLBACK=0"
call :FETCH_MODELS
if errorlevel 1 (
  exit /b 1
)

call :MERGE_CONFIG
if errorlevel 1 (
  exit /b 1
)
del "%MODELS_TMP%" 2>nul

echo.
echo [OK] Model listesi guncellendi. Diger ayarlar korundu.
exit /b 0

:: ── Altprogram: model listesini API'den cek ─────────────────
:: Girdi: EVREN_LLM_API_KEY, ALLOW_FALLBACK (1/0).
:: Cikti: %MODELS_TMP% dosyasi (models haritasi JSON). Donus: errorlevel 0/1.
:FETCH_MODELS
set "MODELS_TMP=%TEMP%\evren-models-%RANDOM%.json"
powershell.exe -NoProfile -Command ^
  "$h=@{Authorization='Bearer %EVREN_LLM_API_KEY%'}; " ^
  "try{ $p=Invoke-RestMethod -Uri '%BASE_URL%/models' -Headers $h }catch{ exit 2 }; " ^
  "$names=@{'glm-5.3'='GLM 5.3'; 'deepseek-v4.1-flash'='DeepSeek V4.1 Flash'; 'deepseek-v4-flash'='DeepSeek V4 Flash'; 'qwen3.8-flash-next'='Qwen 3.8 Flash Next'; 'gemma-4-31b'='Gemma 4 31B'; 'qwen3-vl-30b'='Qwen3 VL 30B'; 'mimo-v2.6-pro'='MiMo V2.6 Pro'; 'auto'='EVREN Auto'}; " ^
  "function pn($i){ if($names.ContainsKey($i)){ return $names[$i] }; $a=@{glm='GLM'; qwen='Qwen'; gemma='Gemma'; deepseek='DeepSeek'; mimo='MiMo'; vl='VL'; ocr='OCR'; asr='ASR'}; (($i -split '-') | ForEach-Object { $t=$_; $l=$t.ToLowerInvariant(); if($a.ContainsKey($l)){ $a[$l] } elseif($l -match '^[0-9]+[a-z]*$'){ $t.ToUpperInvariant() } elseif($t.Length -gt 0){ $t.Substring(0,1).ToUpperInvariant()+$t.Substring(1) } else{ $t } }) -join ' ' }; " ^
  "$map=[PSCustomObject]@{}; " ^
  "foreach($m in $p.data){ $id=$m.id; if([string]::IsNullOrWhiteSpace($id)){ continue }; $t=if($m.task){ $m.task }else{ 'chat' }; if($t -notin @('chat','vision_chat')){ continue }; $c=if($m.context_length){ [int]$m.context_length }else{ 128000 }; $o=if($m.default_max_output_tokens){ [int]$m.default_max_output_tokens }else{ 8192 }; $map|Add-Member -NotePropertyName $id -NotePropertyValue ([PSCustomObject]@{name=(pn $id); limit=[PSCustomObject]@{context=$c; output=$o}}) -Force }; " ^
  "if(($map.PSObject.Properties|Measure-Object).Count -eq 0){ exit 3 }; " ^
  "[System.IO.File]::WriteAllText('%MODELS_TMP%',($map|ConvertTo-Json -Compress -Depth 5),[System.Text.UTF8Encoding]::new($false))"
if errorlevel 3 (
  echo HATA: API sohbet modeli dondurmedi.
  exit /b 1
)
if errorlevel 2 (
  if "%ALLOW_FALLBACK%"=="1" (
    echo [UYARI] Model listesi API'den alinamadi; son bilinen liste kullanilacak.
    powershell.exe -NoProfile -Command ^
      "$map=[PSCustomObject]@{'glm-5.3'=[PSCustomObject]@{name='GLM 5.3'; limit=[PSCustomObject]@{context=524288; output=16384}}; " ^
      " 'deepseek-v4.1-flash'=[PSCustomObject]@{name='DeepSeek V4.1 Flash'; limit=[PSCustomObject]@{context=1048576; output=16384}}; " ^
      " 'deepseek-v4-flash'=[PSCustomObject]@{name='DeepSeek V4 Flash'; limit=[PSCustomObject]@{context=1048576; output=16384}}; " ^
      " 'qwen3.8-flash-next'=[PSCustomObject]@{name='Qwen 3.8 Flash Next'; limit=[PSCustomObject]@{context=262144; output=16384}}; " ^
      " 'gemma-4-31b'=[PSCustomObject]@{name='Gemma 4 31B'; limit=[PSCustomObject]@{context=262144; output=16384}}; " ^
      " 'qwen3-vl-30b'=[PSCustomObject]@{name='Qwen3 VL 30B'; limit=[PSCustomObject]@{context=262144; output=16384}}; " ^
      " 'mimo-v2.6-pro'=[PSCustomObject]@{name='MiMo V2.6 Pro'; limit=[PSCustomObject]@{context=1048576; output=16384}}; " ^
      " 'auto'=[PSCustomObject]@{name='EVREN Auto'; limit=[PSCustomObject]@{context=32768; output=16384}} }; " ^
      "[System.IO.File]::WriteAllText('%MODELS_TMP%',($map|ConvertTo-Json -Compress -Depth 5),[System.Text.UTF8Encoding]::new($false))"
    if errorlevel 1 (
      echo HATA: Yedek model listesi yazilamadi.
      exit /b 1
    )
    exit /b 0
  )
  echo HATA: Model listesi alinamadi. Internet baglantinizi ve anahtarinizi kontrol edin.
  exit /b 1
)
if errorlevel 1 (
  echo HATA: Model listesi alinirken hata olustu.
  exit /b 1
)
echo [OK] Model listesi API'den alindi.
exit /b 0

:: ── Altprogram: %MODELS_TMP% haritasini opencode.jsonc'ye merge et ──
:MERGE_CONFIG
powershell.exe -NoProfile -Command ^
  "$configPath='%CONFIG_PATH%'; $apiKeyRef='%API_KEY_REF%'; $schema='https://opencode.ai/config.json'; " ^
  "$map=Get-Content '%MODELS_TMP%' -Raw -Encoding UTF8 | ConvertFrom-Json; " ^
  "$evren=[PSCustomObject]@{ npm='@ai-sdk/openai-compatible'; name='EVREN LLM'; " ^
  "  options=[PSCustomObject]@{ baseURL='https://evren-llmapi.ssyz.org.tr/v1'; apiKey=$apiKeyRef }; models=$map }; " ^
  "if(Test-Path $configPath){ $raw=Get-Content $configPath -Raw -Encoding UTF8; " ^
  "  $stripped=$raw -replace '(?m)^\s*//.*$','' -replace '/\*[\s\S]*?\*/','' -replace ',\s*([}\]])','$1'; " ^
  "  try{ $cfg=$stripped|ConvertFrom-Json }catch{ $cfg=[PSCustomObject]@{} } " ^
  "}else{ $cfg=[PSCustomObject]@{} }; " ^
  "if(-not $cfg.PSObject.Properties['$schema']){$cfg|Add-Member -NotePropertyName '$schema' -NotePropertyValue $schema -Force}; " ^
  "if(-not $cfg.PSObject.Properties['provider']){$cfg|Add-Member -NotePropertyName 'provider' -NotePropertyValue ([PSCustomObject]@{}) -Force}; " ^
  "$cfg.provider|Add-Member -NotePropertyName 'evren' -NotePropertyValue $evren -Force; " ^
  "$ids=@($map.PSObject.Properties.Name); " ^
  "if((-not $cfg.PSObject.Properties['model']) -or (($cfg.model -like 'evren/*') -and ($ids -notcontains ($cfg.model -replace '^evren/','')))){ if($ids -contains 'glm-5.3'){$d='evren/glm-5.3'}elseif($ids -contains 'auto'){$d='evren/auto'}else{$d='evren/'+$ids[0]}; $cfg|Add-Member -NotePropertyName 'model' -NotePropertyValue $d -Force }; " ^
  "if((-not $cfg.PSObject.Properties['small_model']) -or (($cfg.small_model -like 'evren/*') -and ($ids -notcontains ($cfg.small_model -replace '^evren/','')))){ if($ids -contains 'deepseek-v4.1-flash'){$s='evren/deepseek-v4.1-flash'}else{$s='evren/'+(($map.PSObject.Properties|Sort-Object{$_.Value.limit.context}|Select-Object -First 1).Name)}; $cfg|Add-Member -NotePropertyName 'small_model' -NotePropertyValue $s -Force }; " ^
  "[System.IO.File]::WriteAllText($configPath,($cfg|ConvertTo-Json -Depth 10),[System.Text.UTF8Encoding]::new($false))"
if errorlevel 1 (
  echo HATA: opencode.jsonc guncellenemedi.
  exit /b 1
)
echo [OK] OpenCode config guncellendi ^(mevcut provider'lar korundu^): %CONFIG_PATH%
exit /b 0
