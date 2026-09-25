# evren-llm-opencode

[OpenCode](https://opencode.ai) aracına EVREN LLM provider'ını tek komutla kurar.
Windows (CMD ve PowerShell) ile Linux/macOS (Bash/Zsh) desteği sunar.

[English documentation](README-EN.md)

---

## Hızlı Kurulum

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/bykemalh/evren-llm-opencode/main/evren-opencode.sh | bash
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

Kurulumun yaptığı tüm değişiklikleri geri alır: `opencode.jsonc` içinden `evren` provider bloğunu siler, `EVREN_LLM_API_KEY` ortam değişkenini temizler, `.evren-key` dosyasını siler. Diğer provider'lar ve ayarlar olduğu gibi korunur.

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

1. **API Anahtarı** — Anahtarınızı gizli olarak (ekranda görünmeden) girer, `evren_llm_...` formatını doğrular. Anahtarı iki yere yazar: shell RC dosyalarına (`~/.bashrc`, `~/.zshrc`, `~/.profile`, fish config — terminal/curl kullanımı için) ve `~/.config/opencode/.evren-key` dosyasına (`chmod 600` — opencode'un okuduğu asıl kaynak).
2. **Kullanım Şartları** — EVREN'in kullanım şartlarını API üzerinden çeker, ekranda gösterir ve onayınızı ister. Daha önce kabul ettiyseniz bu adım atlanır.
3. **Config Birleştirme** — Mevcut `~/.config/opencode/opencode.jsonc` dosyasını okur, `evren` provider bloğunu ekler veya günceller, geri kalan her şeyi olduğu gibi bırakır. Dosya yoksa sıfırdan oluşturur. Yazmadan önce zaman damgalı bir yedek alır. Her modele muhafazakar `limit` (context/output) yazar; böylece opencode'un varsayılan 32k output isteğiyle "max_tokens too large" / gereksiz rate-limit baskısı oluşmaz. `small_model` yoksa `evren/deepseek-v4.1-flash` atanır (başlık gibi hafif işler ana modeli yormaz).
4. **Doğrulama** — `opencode models` komutunu hem normal hem de `env` boşaltılmış şekilde çalıştırarak (GUI/IDE simülasyonu) provider'ın tanındığını teyit eder.

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
| `evren/deepseek-v4.1-flash` | DeepSeek V4.1 Flash |
| `evren/deepseek-v4-flash` | DeepSeek V4 Flash *(1 Kasım 2026'da kaldırılacak)* |
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

Anahtar bu dosyaya hiçbir zaman yazılmaz. Config, anahtarı dosya referansıyla okur
(bu sayede `.bashrc` okumayan GUI/IDE/desktop başlatmalarında da çalışır;
`{env:...}` o ortamlarda boş gelip "API key yok" hatası veriyordu):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "evren/glm-5.3",
  "small_model": "evren/deepseek-v4.1-flash",
  "provider": {
    "evren": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "EVREN LLM",
      "options": {
        "baseURL": "https://evren-llmapi.ssyz.org.tr/v1",
        "apiKey": "{file:~/.config/opencode/.evren-key}"
      },
      "models": {
        "glm-5.3":             { "name": "GLM 5.3", "limit": { "context": 200000, "output": 16384 } },
        "deepseek-v4.1-flash": { "name": "DeepSeek V4.1 Flash", "limit": { "context": 128000, "output": 8192 } },
        "deepseek-v4-flash":   { "name": "DeepSeek V4 Flash", "limit": { "context": 128000, "output": 8192 } },
        "qwen3.8-flash-next":  { "name": "Qwen 3.8 Flash Next", "limit": { "context": 128000, "output": 8192 } },
        "gemma-4-31b":         { "name": "Gemma 4 31B", "limit": { "context": 128000, "output": 8192 } },
        "qwen3-vl-30b":        { "name": "Qwen3 VL 30B", "limit": { "context": 128000, "output": 8192 } },
        "auto":                { "name": "EVREN Auto", "limit": { "context": 128000, "output": 8192 } }
      }
    }
  }
}
```

Gerçek anahtar `~/.config/opencode/.evren-key` dosyasındadır (`chmod 600`).
Terminalde doğrudan `curl` için `EVREN_LLM_API_KEY` ortam değişkeni de yazılır.

---

## Kurulum Sonrası

```bash
# Mevcut modelleri listele
opencode models

# Hızlı test
opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."
```

Ortam değişkeni yeni terminal oturumlarında otomatik yüklenir. Hemen aktif etmek için mevcut oturumda `source ~/.bashrc` (veya `.zshrc`) çalıştırın ya da yeni bir terminal açın. **opencode'un kendisi terminal yeniden başlatmayı gerektirmez** çünkü anahtarı `.evren-key` dosyasından okur.

---

## Sorun Giderme

| Sorun | Çözüm |
|-------|-------|
| `opencode` bulunamadı | [opencode.ai](https://opencode.ai) adresinden kurun |
| API anahtarı reddedildi | `evren_llm_` ile başladığını kontrol edin |
| Linux'ta "API key yok" / 401 | Kurulum scriptini yeniden çalıştırın; `~/.config/opencode/.evren-key` dosyasının var olduğunu ve config'de `apiKey` alanının `{file:~/.config/opencode/.evren-key}` olduğunu doğrulayın (`opencode debug config` ile bakın). Eski `{env:...}` referansı, `.bashrc` okumayan GUI/IDE başlatmalarında boş gelir |
| `İstek limiti aşıldı. 5 saniye sonra tekrar deneyin.` (429 `rate_limit_exceeded`) | EVREN API hızlı ardışık isteklere 5 sn soğuma uygular. opencode ile tek görev çalıştırın, paralel ajan/oturum açmayın; 429 alınca birkaç saniye bekleyip tekrar deneyin. `small_model` (`evren/deepseek-v4.1-flash`) başlık gibi yan işleri üstlenerek ana model yükünü azaltır |
| `max_tokens is too large` | Scriptin yazdığı `limit.output` değerlerini kullanın (bu repo günceldir); config'i elle düzenlediyseniz model başına `limit: {context, output}` ekleyin |
| Terms API erişim hatası | İnternet bağlantınızı ve anahtar geçerliliğinizi kontrol edin |
| Config parse hatası | `.bak-...` uzantılı yedek dosyayı geri yükleyin |
| Ortam değişkeni terminalde görünmüyor | Yeni terminal açın veya `source ~/.bashrc` çalıştırın (sadece doğrudan `curl` kullanımı için gerekli; opencode dosya referansıyla çalışır) |

---

## Lisans

Bu repo [MIT lisansı](LICENSE) ile lisanslanmıştır.

EVREN LLM API kullanımı [EVREN Kullanım Şartları](https://evren.ssyz.org.tr)'na tabidir.
