#!/usr/bin/env bash
# ============================================================
# EVREN LLM + OpenCode Kurulum / Kaldirma Scripti (Linux/macOS)
#
# Kullanim:
#   ./evren-opencode.sh              (kurulum)
#   ./evren-opencode.sh --uninstall  (kaldirma)
#
# Kurulum:
#   - API key'i gizli alir, shell RC dosyasina kalici olarak yazar
#   - EVREN kullanim sartlarini gosterir / kabul alir
#   - opencode.jsonc icindeki mevcut ayarlara dokunmadan
#     "evren" provider blogunu ekler / gunceller
#
# Kaldirma:
#   - opencode.jsonc'den "evren" blogunu cikarir
#   - Shell RC dosyasindan EVREN_LLM_API_KEY satirini siler
#   - Diger provider / ayarlar korunur
# ============================================================

set -euo pipefail

BASE_URL="https://evren-llmapi.ssyz.org.tr/v1"
CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_PATH="${CONFIG_DIR}/opencode.jsonc"

# Kullanılan shell RC dosyasını belirle
shell_name="$(basename "${SHELL:-bash}")"
case "$shell_name" in
  zsh)  RC_FILE="${HOME}/.zshrc"   ;;
  bash) RC_FILE="${HOME}/.bashrc"  ;;
  *)    RC_FILE="${HOME}/.profile" ;;
esac

# ── Yardımcı fonksiyonlar ─────────────────────────────────────────────────────

fail() { printf '\nHATA: %s\n' "$1" >&2; exit 1; }
ok()   { printf '[OK] %s\n'   "$1"; }
info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[UYARI] %s\n' "$1"; }

command -v curl >/dev/null 2>&1 || fail "curl bulunamadi. Lutfen onceden yukleyin."

# JSON merge/edit için python3 veya jq gerekli
json_tool=""
if command -v python3 >/dev/null 2>&1; then
  json_tool="python3"
elif command -v jq >/dev/null 2>&1; then
  json_tool="jq"
else
  fail "JSON islemi icin python3 veya jq gerekli. Lutfen birini yukleyin."
fi

# Config'i yedekler
backup_config() {
  if [[ -f "$CONFIG_PATH" ]]; then
    local bak="${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_PATH" "$bak"
    info "Mevcut config yedeklendi: $bak"
  fi
}

# Python3 ile JSON merge: mevcut JSON'a provider.evren bloğunu ekle/güncelle
merge_config_python() {
python3 - "$CONFIG_PATH" <<'PYEOF'
import sys, json, os

config_path = sys.argv[1]
config_dir  = os.path.dirname(config_path)
os.makedirs(config_dir, exist_ok=True)

evren_block = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "EVREN LLM",
    "options": {
        "baseURL": "https://evren-llmapi.ssyz.org.tr/v1",
        "apiKey":  "{env:EVREN_LLM_API_KEY}"
    },
    "models": {
        "glm-5.3":            {"name": "GLM 5.3"},
        "deepseek-v4-flash":  {"name": "DeepSeek V4 Flash"},
        "qwen3.8-flash-next": {"name": "Qwen 3.8 Flash Next"},
        "gemma-4-31b":        {"name": "Gemma 4 31B"},
        "qwen3-vl-30b":       {"name": "Qwen3 VL 30B"},
        "auto":               {"name": "EVREN Auto"}
    }
}

cfg = {}
if os.path.isfile(config_path):
    raw = open(config_path, encoding="utf-8").read()
    # Basit JSONC yorum temizleme
    import re
    raw = re.sub(r'(?m)^\s*//.*$', '', raw)
    raw = re.sub(r'/\*[\s\S]*?\*/', '', raw)
    try:
        cfg = json.loads(raw)
    except Exception:
        cfg = {}

cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("model",   "evren/glm-5.3")
cfg.setdefault("provider", {})
cfg["provider"]["evren"] = evren_block

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"[OK] opencode.jsonc guncellendi: {config_path}")
PYEOF
}

# jq ile JSON merge
merge_config_jq() {
  local evren_json
  evren_json=$(cat <<'JSON'
{
  "npm": "@ai-sdk/openai-compatible",
  "name": "EVREN LLM",
  "options": {
    "baseURL": "https://evren-llmapi.ssyz.org.tr/v1",
    "apiKey":  "{env:EVREN_LLM_API_KEY}"
  },
  "models": {
    "glm-5.3":            {"name": "GLM 5.3"},
    "deepseek-v4-flash":  {"name": "DeepSeek V4 Flash"},
    "qwen3.8-flash-next": {"name": "Qwen 3.8 Flash Next"},
    "gemma-4-31b":        {"name": "Gemma 4 31B"},
    "qwen3-vl-30b":       {"name": "Qwen3 VL 30B"},
    "auto":               {"name": "EVREN Auto"}
  }
}
JSON
)
  mkdir -p "$CONFIG_DIR"
  local base="{}"
  [[ -f "$CONFIG_PATH" ]] && base="$(cat "$CONFIG_PATH")"

  # jq: $schema yoksa ekle, model yoksa ekle, provider.evren'i güncelle
  printf '%s' "$base" | jq \
    --argjson evren "$evren_json" \
    '
      if has("$schema") then . else . + {"$schema": "https://opencode.ai/config.json"} end |
      if has("model")   then . else . + {"model": "evren/glm-5.3"} end |
      .provider //= {} |
      .provider.evren = $evren
    ' > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

  ok "opencode.jsonc guncellendi: $CONFIG_PATH"
}

# Python3 ile evren bloğunu sil
remove_evren_python() {
python3 - "$CONFIG_PATH" <<'PYEOF'
import sys, json, os, re

config_path = sys.argv[1]
if not os.path.isfile(config_path):
    print("[INFO] opencode.jsonc bulunamadi; degisiklik yapilmadi.")
    sys.exit(0)

raw = open(config_path, encoding="utf-8").read()
raw = re.sub(r'(?m)^\s*//.*$', '', raw)
raw = re.sub(r'/\*[\s\S]*?\*/', '', raw)

try:
    cfg = json.loads(raw)
except Exception:
    print("[INFO] JSON parse hatasi; degisiklik yapilmadi.")
    sys.exit(0)

removed = False
if "provider" in cfg and "evren" in cfg["provider"]:
    del cfg["provider"]["evren"]
    removed = True
    if not cfg["provider"]:
        del cfg["provider"]

if cfg.get("model", "").startswith("evren/"):
    del cfg["model"]
    print("[INFO] Varsayilan model 'evren/...' kaldirildi.")

if removed:
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("[OK] 'evren' provider blogu kaldirildi.")
else:
    print("[INFO] 'evren' blogu bulunamadi; config degistirilmedi.")
PYEOF
}

# jq ile evren bloğunu sil
remove_evren_jq() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    info "opencode.jsonc bulunamadi; degisiklik yapilmadi."
    return
  fi
  jq '
    if .provider.evren? then
      del(.provider.evren) |
      if (.provider | length) == 0 then del(.provider) else . end
    else . end |
    if (.model? // "") | startswith("evren/") then del(.model) else . end
  ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
  ok "'evren' provider blogu kaldirildi (veya zaten yoktu)."
}

# ── Parametre kontrolü ────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
  # ══════════════════════════════════════════════════════════
  #  KALDIRMA
  # ══════════════════════════════════════════════════════════
  printf '=== EVREN LLM OpenCode Kaldirma ===\n'

  backup_config

  if [[ "$json_tool" == "python3" ]]; then
    remove_evren_python
  else
    remove_evren_jq
  fi

  # Shell RC dosyasından EVREN_LLM_API_KEY satırını sil
  if [[ -f "$RC_FILE" ]]; then
    tmp_rc="$(mktemp)"
    grep -v '^[[:space:]]*export[[:space:]][[:space:]]*EVREN_LLM_API_KEY=' "$RC_FILE" > "$tmp_rc" || true
    cat "$tmp_rc" > "$RC_FILE"
    rm -f "$tmp_rc"
    ok "EVREN_LLM_API_KEY $RC_FILE dosyasindan kaldirildi."
  else
    info "RC dosyasi bulunamadi ($RC_FILE); degisiklik yapilmadi."
  fi

  printf '\n'
  ok "Kaldirma tamamlandi. Diger provider/ayarlar korundu."
  printf 'Not: Degisiklikler yeni acilan terminal oturumlarinda gecerli olur.\n'
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  KURULUM
# ══════════════════════════════════════════════════════════════════════════════

printf '=== EVREN LLM + OpenCode Kurulumu ===\n'

# ── 1) API key al ─────────────────────────────────────────────────────────────
# Not: `curl ... | bash` ile calistirildiginda stdin pipe olur; klavyeden
# (yapistirma ile) okuyabilmek icin dogrudan terminalden oku.
if [[ -r /dev/tty ]]; then
  IFS= read -r -s -p "EVREN LLM API key'inizi girin: " EVREN_LLM_API_KEY </dev/tty
else
  IFS= read -r -s -p "EVREN LLM API key'inizi girin: " EVREN_LLM_API_KEY
fi
printf '\n'

# Yapistirmadan gelebilecek \r / bas-son bosluklari temizle
EVREN_LLM_API_KEY="$(printf '%s' "$EVREN_LLM_API_KEY" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [[ ! "$EVREN_LLM_API_KEY" =~ ^evren_llm_[A-Za-z0-9_-]+$ ]]; then
  fail "API key beklenen evren_llm_... formatinda degil."
fi

export EVREN_LLM_API_KEY

# Shell RC dosyasına kalıcı olarak yaz
touch "$RC_FILE"
tmp_rc="$(mktemp)"
grep -v '^[[:space:]]*export[[:space:]][[:space:]]*EVREN_LLM_API_KEY=' "$RC_FILE" > "$tmp_rc" || true
cat "$tmp_rc" > "$RC_FILE"
rm -f "$tmp_rc"
printf "\nexport EVREN_LLM_API_KEY='%s'\n" "$EVREN_LLM_API_KEY" >> "$RC_FILE"
chmod 600 "$RC_FILE" 2>/dev/null || true
ok "EVREN_LLM_API_KEY $RC_FILE dosyasina kalici olarak yazildi."

auth_header="Authorization: Bearer ${EVREN_LLM_API_KEY}"

# ── 2) Terms durumunu kontrol et ─────────────────────────────────────────────

status_json="$(curl -fsS "${BASE_URL}/terms/status" -H "$auth_header")" \
  || fail "EVREN terms/status cagrisi basarisiz."

version="$(printf '%s' "$status_json" | sed -n 's/.*"current_version"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
accepted="$(printf '%s' "$status_json" | sed -n 's/.*"accepted"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')"

[[ -n "$version" ]] || fail "current_version okunamadi."
[[ -n "$accepted" ]] || fail "accepted alani okunamadi."

if [[ "$accepted" != "true" ]]; then
  terms_json="$(curl -fsS "${BASE_URL}/terms/text" -H "$auth_header")" \
    || fail "EVREN terms/text cagrisi basarisiz."

  printf '\n=== EVREN Kullanim Sartlari (v%s) ===\n' "$version"

  if [[ "$json_tool" == "python3" ]]; then
    printf '%s' "$terms_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["content"])'
  else
    printf '%s' "$terms_json" | jq -r '.content'
  fi

  printf '\n'
  if [[ -r /dev/tty ]]; then
    read -r -p "Bu kullanim sartlarini kabul ediyor musunuz? Kabul icin EVET yazin: " confirmation </dev/tty
  else
    read -r -p "Bu kullanim sartlarini kabul ediyor musunuz? Kabul icin EVET yazin: " confirmation
  fi
  confirmation_upper="$(printf '%s' "$confirmation" | tr '[:lower:]' '[:upper:]')"
  [[ "$confirmation_upper" == "EVET" ]] || fail "Kullanim sartlari kabul edilmedi. Kurulum durduruldu."

  curl -fsS -X POST "${BASE_URL}/terms/accept" \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    --data "{\"version\":${version}}" >/dev/null \
    || fail "EVREN terms/accept cagrisi basarisiz."

  ok "EVREN kullanim sartlari v${version} kabul edildi."
else
  ok "EVREN kullanim sartlari zaten kabul edilmis (v${version})."
fi

# ── 3) Kabul durumunu yeniden doğrula ────────────────────────────────────────

verify_json="$(curl -fsS "${BASE_URL}/terms/status" -H "$auth_header")" \
  || fail "Kabul dogrulamasi basarisiz."

verify_accepted="$(printf '%s' "$verify_json" | sed -n 's/.*"accepted"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')"
[[ "$verify_accepted" == "true" ]] || fail "EVREN kullanim sartlari accepted=true olarak dogrulanamadi."
ok "Terms kabul durumu dogrulandi."

# ── 4) opencode.jsonc merge ──────────────────────────────────────────────────

mkdir -p "$CONFIG_DIR"
backup_config

if [[ "$json_tool" == "python3" ]]; then
  merge_config_python
else
  merge_config_jq
fi

chmod 600 "$CONFIG_PATH" 2>/dev/null || true

# ── 5) OpenCode doğrulaması ──────────────────────────────────────────────────

if command -v opencode >/dev/null 2>&1; then
  printf '\n=== opencode models ===\n'
  opencode models || fail "opencode models komutu basarisiz oldu."
  printf '\n'
  ok "OpenCode EVREN provider'i okuyabiliyor."
  printf '\nTest komutu:\n'
  printf '%s\n' 'opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."'
  printf '\nKaldirmak icin:\n'
  printf '%s\n' './evren-opencode.sh --uninstall'
else
  printf '\n'
  warn "'opencode' PATH icinde bulunamadi. Config yine de guncellendi."
  printf 'OpenCode kurulduktan sonra su komutlari calistirin:\n'
  printf '  opencode models\n'
  printf '  opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."\n'
  printf '\nKaldirmak icin: ./evren-opencode.sh --uninstall\n'
fi

printf '\nNot: Kalici env degiskeni yeni terminal oturumlarinda otomatik yuklenir.\n'
