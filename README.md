# evren-llm-opencode

[OpenCode](https://opencode.ai) aracına EVREN LLM provider'ını tek komutla kurar.
Windows (CMD ve PowerShell) ile Linux/macOS (Bash/Zsh) desteği sunar.

[English documentation](README-EN.md)

---

## Hızlı Kurulum

### Linux / macOS

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/bykemalh/evren-llm-opencode/main/evren-opencode.sh")
```

### Windows — PowerShell

```powershell
irm "https://raw.githubusercontent.com/bykemalh/evren-llm-opencode/main/evren-opencode.ps1" | iex
```

> PowerShell'i normal kullanıcı olarak çalıştırın, Yönetici olarak değil.

### Windows — CMD

CMD scriptleri doğrudan pipe ile çalıştırılamaz. İki adımda indirip çalıştırın:

```cmd
curl -fsSL "https://raw.githubusercontent.com/bykemalh/evren-llm-opencode/main/evren-opencode.cmd" -o "%TEMP%\evren-opencode.cmd" && call "%TEMP%\evren-opencode.cmd"
```

---

## Kaldırma

Kurulumun yaptığı tüm değişiklikleri geri alır: `opencode.jsonc` içinden `evren` provider bloğunu siler, `EVREN_LLM_API_KEY` ortam değişkenini temizler. Diğer provider'lar ve ayarlar olduğu gibi korunur.

```bash
# Linux / macOS
./evren-opencode.sh --uninstall
```

```powershell
# Windows PowerShell
.\evren-opencode.ps1 --uninstall
```

```cmd
:: Windows CMD
evren-opencode.cmd --uninstall
```

---

## Kurulum Adımları

1. **API Anahtarı** — Anahtarınızı gizli olarak (ekranda görünmeden) girer, `evren_llm_...` formatını doğrular ve kalıcı kullanıcı ortam değişkeni olarak kaydeder.
2. **Kullanım Şartları** — EVREN'in kullanım şartlarını API üzerinden çeker, ekranda gösterir ve onayınızı ister. Daha önce kabul ettiyseniz bu adım atlanır.
3. **Config Birleştirme** — Mevcut `~/.config/opencode/opencode.jsonc` dosyasını okur, `evren` provider bloğunu ekler veya günceller, geri kalan her şeyi olduğu gibi bırakır. Dosya yoksa sıfırdan oluşturur. Yazmadan önce zaman damgalı bir yedek alır.
4. **Doğrulama** — `opencode models` komutunu çalıştırarak provider'ın tanındığını teyit eder.

### Config Birleştirme Davranışı

| Durum | Sonuç |
|-------|-------|
| `opencode.jsonc` mevcut değil | Sıfırdan oluşturulur |
| `evren` bloğu yok | Eklenir; diğer provider'lar korunur |
| `evren` bloğu zaten var | Yerinde güncellenir |
| `model` alanı daha önce ayarlanmış | Değiştirilmez |
| `model` alanı boş | `evren/glm-5.3` yazılır |

---

## Gereksinimler

| | Linux / macOS | Windows |
|---|---|---|
| curl | Gerekli | Yerleşik (Windows 10+) |
| JSON aracı | python3 **veya** jq | PowerShell yerleşik |
| OpenCode | Önerilen (script için zorunlu değil) | Önerilen |

API anahtarınızı almak için: [evren.ssyz.org.tr/api-keys](https://evren.ssyz.org.tr/api-keys)

---

## Desteklenen Modeller

Tam model listesi ve ayrıntı: [evren.ssyz.org.tr/llm/models](https://evren.ssyz.org.tr/llm/models)

| Model ID | Görünen Ad |
|----------|-----------|
| `evren/glm-5.3` | GLM 5.3 (varsayılan) |
| `evren/deepseek-v4-flash` | DeepSeek V4 Flash |
| `evren/qwen3.8-flash-next` | Qwen 3.8 Flash Next |
| `evren/gemma-4-31b` | Gemma 4 31B |
| `evren/qwen3-vl-30b` | Qwen3 VL 30B |
| `evren/auto` | EVREN Auto |

---

## API Anahtarı Formatı

Anahtarlar şu şekilde başlar:

```
evren_llm_<alfanumerik>
```

Anahtarınızı buradan alın: [evren.ssyz.org.tr/api-keys](https://evren.ssyz.org.tr/api-keys)

---

## Config Dosyası Konumu

| Platform | Yol |
|----------|-----|
| Linux / macOS | `~/.config/opencode/opencode.jsonc` |
| Windows | `%USERPROFILE%\.config\opencode\opencode.jsonc` |

Anahtar bu dosyaya hiçbir zaman yazılmaz. Config her zaman ortam değişkenine referans verir:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "evren/glm-5.3",
  "provider": {
    "evren": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "EVREN LLM",
      "options": {
        "baseURL": "https://evren-llmapi.ssyz.org.tr/v1",
        "apiKey": "{env:EVREN_LLM_API_KEY}"
      },
      "models": {
        "glm-5.3":            { "name": "GLM 5.3" },
        "deepseek-v4-flash":  { "name": "DeepSeek V4 Flash" },
        "qwen3.8-flash-next": { "name": "Qwen 3.8 Flash Next" },
        "gemma-4-31b":        { "name": "Gemma 4 31B" },
        "qwen3-vl-30b":       { "name": "Qwen3 VL 30B" },
        "auto":               { "name": "EVREN Auto" }
      }
    }
  }
}
```

---

## Kurulum Sonrası

```bash
# Mevcut modelleri listele
opencode models

# Hızlı test
opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."
```

Ortam değişkeni yeni terminal oturumlarında otomatik yüklenir. Hemen aktif etmek için mevcut oturumda `source ~/.bashrc` (veya `.zshrc`) çalıştırın ya da yeni bir terminal açın.

---

## Sorun Giderme

| Sorun | Çözüm |
|-------|-------|
| `opencode` bulunamadı | [opencode.ai](https://opencode.ai) adresinden kurun |
| API anahtarı reddedildi | `evren_llm_` ile başladığını kontrol edin |
| Terms API erişim hatası | İnternet bağlantınızı ve anahtar geçerliliğinizi kontrol edin |
| Config parse hatası | `.bak-...` uzantılı yedek dosyayı geri yükleyin |
| Ortam değişkeni görünmüyor | Yeni terminal açın (kalıcı değişkenler yeni oturumda yüklenir) |

---

## Lisans

Bu repodaki scriptler açık kaynaktır. EVREN LLM API kullanımı [EVREN Kullanım Şartları](https://evren.ssyz.org.tr)'na tabidir.
