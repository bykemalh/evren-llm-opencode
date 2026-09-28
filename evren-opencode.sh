#!/usr/bin/env bash
# ============================================================
# EVREN LLM + OpenCode Kurulum / Kaldirma Scripti (Linux/macOS)
#
# Kullanim:
#   ./evren-opencode.sh                (kurulum)
#   ./evren-opencode.sh --sync-models  (sadece model listesini tazele)
#   ./evren-opencode.sh --uninstall    (kaldirma)
#
# Kurulum:
#   - API key'i gizli alir
#   - Anahtari SHELL RC dosyalarina (bash/zsh/profile/fish) VE
#     ~/.config/opencode/.evren-key dosyasina yazar (chmod 600)
#   - Config'deki apiKey "{file:~/.config/opencode/.evren-key}" referansi
#     kullanir: boylece GUI/IDE/desktop'ten baslatilan opencode da
#     calisir (RC dosyalarini okumayan ortamlarda {env:...} bos gelir)
#   - EVREN kullanim sartlarini gosterir / kabul alir
#   - Model listesini API'den (/v1/models) otomatik ceker ve
#     opencode.jsonc icindeki mevcut ayarlara dokunmadan
#     "evren" provider blogunu ekler / gunceller (tam senkron)
#
# --sync-models:
#   - Kayitli anahtari (.evren-key) kullanir, anahtar sormaz
#   - Terms adimini atlar; sadece model listesini API'den cekip
#     config'deki "evren" provider blogunu gunceller
#
# Model senkronu (kurulum + --sync-models):
#   - Sadece sohbet modelleri yazilir (task: chat / vision_chat);
#     embedding/rerank/ocr/ses modelleri elenir
#   - limit.context API'deki context_length'ten, limit.output
#     default_max_output_tokens'tan alinir (null ise 8192)
#   - API'de olmayan modeller config'den silinir (tam senkron);
#     gecersiz kalan model/small_model guvenli degere alinir
#   - API'ye erisilemezse kurulum son bilinen listeyle tamamlanir (uyariyla)
#
# Kaldirma:
#   - opencode.jsonc'den "evren" blogunu cikarir
#   - Shell RC dosyalarindan EVREN_LLM_API_KEY satirini siler
#   - .evren-key dosyasini siler
#   - Diger provider / ayarlar korunur
# ============================================================

set -euo pipefail

BASE_URL="https://evren-llmapi.ssyz.org.tr/v1"
CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_PATH="${CONFIG_DIR}/opencode.jsonc"
KEY_FILE="${CONFIG_DIR}/.evren-key"
# Config icine yazilan apiKey referansi (shell'den bagimsiz calisir)
API_KEY_REF="{file:~/.config/opencode/.evren-key}"

# Kalici env icin hedef RC dosyalari.
# NOT: $SHELL tek basina guvenilmez (fish/zsh/karmasik kurulumlar, desktop
# baslaticilari). Bu yuzden var olan tum yaygin RC dosyalarina yazilir.
RC_FILES=()
[[ -f "${HOME}/.bashrc" ]] && RC_FILES+=("${HOME}/.bashrc")
[[ -f "${HOME}/.zshrc" ]] && RC_FILES+=("${HOME}/.zshrc")
[[ -f "${HOME}/.profile" ]] && RC_FILES+=("${HOME}/.profile")
[[ -f "${HOME}/.bash_profile" ]] && RC_FILES+=("${HOME}/.bash_profile")
if [[ ${#RC_FILES[@]} -eq 0 ]]; then
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh)  RC_FILES=("${HOME}/.zshrc")   ;;
    bash) RC_FILES=("${HOME}/.bashrc")  ;;
    *)    RC_FILES=("${HOME}/.profile") ;;
  esac
fi
# fish ayri syntax kullanir
FISH_CONFIG="${HOME}/.config/fish/config.fish"

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

# ── Model listesi: API'den otomatik cekme ────────────────────────────────────

# Son bilinen liste (/v1/models yanit seklinde; degerler gercek API degerleridir).
# API erisilemezse kurulum bu listeyle tamamlanir (uyariyla).
FALLBACK_MODELS_JSON='{"object":"list","data":[{"id":"glm-5.3","task":"chat","context_length":524288,"default_max_output_tokens":16384},{"id":"deepseek-v4.1-flash","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"deepseek-v4-flash","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"qwen3.8-flash-next","task":"chat","context_length":262144,"default_max_output_tokens":16384},{"id":"gemma-4-31b","task":"chat","context_length":262144,"default_max_output_tokens":16384},{"id":"qwen3-vl-30b","task":"vision_chat","context_length":262144,"default_max_output_tokens":16384},{"id":"mimo-v2.6-pro","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"auto","task":"chat","context_length":32768,"default_max_output_tokens":16384}]}'

# API'den ham model listesini indirir (stdout: JSON). Basarisizsa 1 doner.
fetch_models_json() {
  curl -fsS --max-time 30 "${BASE_URL}/models" -H "Authorization: Bearer ${1}"
}

# API yanitindan (stdin) opencode "models" haritasi uretir (stdout: JSON).
# Sadece task=chat / vision_chat alinir; limit'ler API degerlerinden gelir.
# NOT: girdi gecici dosyaya alinir; cunku python programi heredoc'tan
# (stdin) okudugu icin veri ayni kanaldan verilemez.
build_models_map() {
  local input_tmp
  input_tmp="$(mktemp)" || return 1
  cat > "$input_tmp" || { rm -f "$input_tmp"; return 1; }
  if [[ "$json_tool" == "python3" ]]; then
    python3 - "$input_tmp" <<'PYEOF'
import sys, json, re

KNOWN_NAMES = {
    "glm-5.3": "GLM 5.3",
    "deepseek-v4.1-flash": "DeepSeek V4.1 Flash",
    "deepseek-v4-flash": "DeepSeek V4 Flash",
    "qwen3.8-flash-next": "Qwen 3.8 Flash Next",
    "gemma-4-31b": "Gemma 4 31B",
    "qwen3-vl-30b": "Qwen3 VL 30B",
    "mimo-v2.6-pro": "MiMo V2.6 Pro",
    "auto": "EVREN Auto",
}
ACRONYMS = {"glm": "GLM", "qwen": "Qwen", "gemma": "Gemma",
            "deepseek": "DeepSeek", "mimo": "MiMo",
            "vl": "VL", "ocr": "OCR", "asr": "ASR"}

def pretty(mid):
    if mid in KNOWN_NAMES:
        return KNOWN_NAMES[mid]
    words = []
    for tok in mid.split("-"):
        low = tok.lower()
        if low in ACRONYMS:
            words.append(ACRONYMS[low])
        elif re.fullmatch(r"[0-9]+[a-z]*", low):
            words.append(tok.upper())
        elif tok:
            words.append(tok[:1].upper() + tok[1:])
        else:
            words.append(tok)
    return " ".join(words) if words else mid

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        payload = json.load(f)
except Exception as e:
    print(f"HATA: model listesi parse edilemedi: {e}", file=sys.stderr)
    sys.exit(1)

models = {}
for m in payload.get("data", []):
    mid = m.get("id")
    if not mid:
        continue
    if m.get("task", "chat") not in ("chat", "vision_chat"):
        continue
    ctx = m.get("context_length") or 128000
    out = m.get("default_max_output_tokens") or 8192
    models[mid] = {"name": pretty(mid),
                   "limit": {"context": ctx, "output": out}}

if not models:
    print("HATA: API sohbet modeli dondurmedi.", file=sys.stderr)
    sys.exit(1)

print(json.dumps(models, ensure_ascii=False))
PYEOF
    local rc=$?
  else
    jq -c '
      {"glm-5.3":"GLM 5.3","deepseek-v4.1-flash":"DeepSeek V4.1 Flash","deepseek-v4-flash":"DeepSeek V4 Flash","qwen3.8-flash-next":"Qwen 3.8 Flash Next","gemma-4-31b":"Gemma 4 31B","qwen3-vl-30b":"Qwen3 VL 30B","mimo-v2.6-pro":"MiMo V2.6 Pro","auto":"EVREN Auto"} as $names
      | (.data // [])
      | map(select((.task // "chat") == "chat" or (.task // "chat") == "vision_chat"))
      | map({key: .id,
             value: {name: (if $names[.id] then $names[.id]
                            else (.id | split("-")
                                  | map(if test("^[0-9]+[a-z]*$"; "i") then ascii_upcase
                                        elif test("^glm$"; "i") then "GLM"
                                        elif test("^qwen$"; "i") then "Qwen"
                                        elif test("^gemma$"; "i") then "Gemma"
                                        elif test("^deepseek$"; "i") then "DeepSeek"
                                        elif test("^mimo$"; "i") then "MiMo"
                                        elif test("^vl$"; "i") then "VL"
                                        else (.[0:1] | ascii_upcase) + .[1:] end)
                                  | join(" ")) end),
                    limit: {context: (.context_length // 128000),
                            output: (.default_max_output_tokens // 8192)}}})
      | from_entries
      | select(length > 0)' "$input_tmp"
    local rc=$?
  fi
  rm -f "$input_tmp"
  return $rc
}

# Config'i yedekler
backup_config() {
  if [[ -f "$CONFIG_PATH" ]]; then
    local bak="${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_PATH" "$bak"
    info "Mevcut config yedeklendi: $bak"
  fi
}

# Python3 ile JSON merge: mevcut JSON'a provider.evren bloğunu ekle/güncelle.
# Model listesi $MODELS_MAP_JSON globalinden alinir (build_models_map ciktisi).
merge_config_python() {
python3 - "$CONFIG_PATH" "$API_KEY_REF" "$MODELS_MAP_JSON" <<'PYEOF'
import sys, json, os

config_path = sys.argv[1]
api_key_ref = sys.argv[2]
models_map  = json.loads(sys.argv[3])
config_dir  = os.path.dirname(config_path)
os.makedirs(config_dir, exist_ok=True)

evren_block = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "EVREN LLM",
    "options": {
        "baseURL": "https://evren-llmapi.ssyz.org.tr/v1",
        "apiKey":  api_key_ref
    },
    # Tam senkron: API listesindeki modellerin birebir aynisi yazilir.
    # API'den kalkan eski modeller config'den silinir.
    "models": models_map
}

cfg = {}
if os.path.isfile(config_path):
    raw = open(config_path, encoding="utf-8").read()
    # Basit JSONC temizleme: // yorum, /* */ yorum, trailing comma
    import re
    raw = re.sub(r'(?m)^\s*//.*$', '', raw)
    raw = re.sub(r'/\*[\s\S]*?\*/', '', raw)
    raw = re.sub(r',\s*([}\]])', r'\1', raw)
    try:
        cfg = json.loads(raw)
    except Exception:
        cfg = {}

def pick_default_model():
    for cand in ("glm-5.3", "auto"):
        if cand in models_map:
            return f"evren/{cand}"
    return f"evren/{next(iter(models_map))}"

def pick_small_model():
    # Baslik/ozet gibi hafif isler icin flash model: ana modelde rate-limit baskisini azaltir
    if "deepseek-v4.1-flash" in models_map:
        return "evren/deepseek-v4.1-flash"
    smallest = min(models_map.items(),
                   key=lambda kv: kv[1].get("limit", {}).get("context", 0))
    return f"evren/{smallest[0]}"

cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("provider", {})
cfg["provider"]["evren"] = evren_block

# model: yoksa veya artik API listesinde degilse guvenli degere al; yoksa koru
cur = cfg.get("model", "")
if not cur or (cur.startswith("evren/") and cur.split("/", 1)[1] not in models_map):
    cfg["model"] = pick_default_model()

cur_small = cfg.get("small_model", "")
if not cur_small or (cur_small.startswith("evren/") and cur_small.split("/", 1)[1] not in models_map):
    cfg["small_model"] = pick_small_model()

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"[OK] opencode.jsonc guncellendi: {config_path} ({len(models_map)} model)")
PYEOF
}

# jq ile JSON merge (JSONC girdiyi python ile once saf JSON'a cevirir).
# Model listesi $MODELS_MAP_JSON globalinden alinir (build_models_map ciktisi).
merge_config_jq() {
  local evren_json
  evren_json="$(jq -n --argjson models "$MODELS_MAP_JSON" --arg ref "$API_KEY_REF" \
    '{npm: "@ai-sdk/openai-compatible", name: "EVREN LLM",
      options: {baseURL: "https://evren-llmapi.ssyz.org.tr/v1", apiKey: $ref},
      models: $models}')" || fail "Model haritasi olusturulamadi."
  mkdir -p "$CONFIG_DIR"
  local base="{}"
  if [[ -f "$CONFIG_PATH" ]]; then
    # JSONC -> JSON (yorum + trailing comma temizle), basarisizsa {}
    base="$(python3 -c 'import sys,re,json; raw=open(sys.argv[1],encoding="utf-8").read(); raw=re.sub(r"(?m)^\s*//.*$","",raw); raw=re.sub(r"/\*[\s\S]*?\*/","",raw); raw=re.sub(r",\s*([}\]])",r"\1",raw);
try: print(json.dumps(json.loads(raw)))
except Exception: print("{}")' "$CONFIG_PATH" 2>/dev/null || printf '{}')"
  fi

  # $schema yoksa ekle; model/small_model yoksa veya artik API listesinde
  # degilse guvenli degere al; provider.evren'i tam senkronla guncelle
  printf '%s' "$base" | jq \
    --argjson evren "$evren_json" \
    '
      if has("$schema") then . else . + {"$schema": "https://opencode.ai/config.json"} end |
      .provider //= {} |
      .provider.evren = $evren |
      ($evren.models) as $m |
      if ((.model // "") == "" or
          ((.model | startswith("evren/")) and ((.model | split("/")[1]) as $id | ($m | has($id) | not))))
      then .model = ($m | if has("glm-5.3") then "evren/glm-5.3"
                          elif has("auto") then "evren/auto"
                          else ("evren/" + (keys[0])) end)
      else . end |
      if ((.small_model // "") == "" or
          ((.small_model | startswith("evren/")) and ((.small_model | split("/")[1]) as $id | ($m | has($id) | not))))
      then .small_model = ($m | if has("deepseek-v4.1-flash") then "evren/deepseek-v4.1-flash"
                                else ("evren/" + (to_entries | min_by(.value.limit.context) | .key)) end)
      else . end
    ' > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

  ok "opencode.jsonc guncellendi: $CONFIG_PATH ($(jq -r 'keys | length' <<<"$MODELS_MAP_JSON") model)"
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
raw = re.sub(r',\s*([}\]])', r'\1', raw)

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

if cfg.get("small_model", "").startswith("evren/"):
    del cfg["small_model"]
    print("[INFO] small_model 'evren/...' kaldirildi.")

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
  local clean
  clean="$(python3 -c 'import sys,re,json; raw=open(sys.argv[1],encoding="utf-8").read(); raw=re.sub(r"(?m)^\s*//.*$","",raw); raw=re.sub(r"/\*[\s\S]*?\*/","",raw); raw=re.sub(r",\s*([}\]])",r"\1",raw);
try: print(json.dumps(json.loads(raw)))
except Exception: print("{}")' "$CONFIG_PATH" 2>/dev/null || printf '{}')"
  printf '%s' "$clean" | jq '
    if .provider.evren? then
      del(.provider.evren) |
      if (.provider | length) == 0 then del(.provider) else . end
    else . end |
    if (.model? // "") | startswith("evren/") then del(.model) else . end |
    if (.small_model? // "") | startswith("evren/") then del(.small_model) else . end
  ' > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
  ok "'evren' provider blogu kaldirildi (veya zaten yoktu)."
}

# Tum RC dosyalarindan EVREN_LLM_API_KEY satirini sil
remove_env_from_rc() {
  local rc
  for rc in "${RC_FILES[@]}"; do
    if [[ -f "$rc" ]]; then
      local tmp_rc
      tmp_rc="$(mktemp)"
      grep -v '^[[:space:]]*export[[:space:]][[:space:]]*EVREN_LLM_API_KEY=' "$rc" > "$tmp_rc" || true
      cat "$tmp_rc" > "$rc"
      rm -f "$tmp_rc"
      ok "EVREN_LLM_API_KEY $rc dosyasindan kaldirildi."
    fi
  done
  if [[ -f "$FISH_CONFIG" ]]; then
    local tmp_fish
    tmp_fish="$(mktemp)"
    grep -v 'EVREN_LLM_API_KEY' "$FISH_CONFIG" > "$tmp_fish" || true
    cat "$tmp_fish" > "$FISH_CONFIG"
    rm -f "$tmp_fish"
    ok "EVREN_LLM_API_KEY $FISH_CONFIG dosyasindan kaldirildi."
  fi
}

# Tum RC dosyalarina kalici export yaz (mevcut satiri once temizler)
write_env_to_rc() {
  local rc
  for rc in "${RC_FILES[@]}"; do
    touch "$rc"
    local tmp_rc
    tmp_rc="$(mktemp)"
    grep -v '^[[:space:]]*export[[:space:]][[:space:]]*EVREN_LLM_API_KEY=' "$rc" > "$tmp_rc" || true
    cat "$tmp_rc" > "$rc"
    rm -f "$tmp_rc"
    # shellcheck disable=SC2016
    printf '\nexport EVREN_LLM_API_KEY='"'"'%s'"'"'\n' "$EVREN_LLM_API_KEY" >> "$rc"
    # NOT: tum .bashrc'yi 600 yapma; sadece anahtar dosyasini koru
    ok "EVREN_LLM_API_KEY $rc dosyasina yazildi."
  done
  # fish kullanicilari icin
  if command -v fish >/dev/null 2>&1; then
    mkdir -p "$(dirname "$FISH_CONFIG")"
    touch "$FISH_CONFIG"
    local tmp_fish
    tmp_fish="$(mktemp)"
    grep -v 'EVREN_LLM_API_KEY' "$FISH_CONFIG" > "$tmp_fish" || true
    cat "$tmp_fish" > "$FISH_CONFIG"
    rm -f "$tmp_fish"
    printf '\nset -gx EVREN_LLM_API_KEY %s\n' "'$EVREN_LLM_API_KEY'" >> "$FISH_CONFIG"
    ok "EVREN_LLM_API_KEY $FISH_CONFIG dosyasina yazildi."
  fi
}

# ── Parametre kontrolü ────────────────────────────────────────────────────────

if [[ "${1:-}" == "--sync-models" || "${1:-}" == "--update-models" ]]; then
  # ══════════════════════════════════════════════════════════
  #  MODEL SENKRONU (anahtar sormaz, terms adimini atlar)
  # ══════════════════════════════════════════════════════════
  printf '=== EVREN LLM Model Listesi Guncellemesi ===\n'

  # Kayitli anahtari kullan (.evren-key yoksa env'e bak)
  if [[ -f "$KEY_FILE" ]]; then
    EVREN_LLM_API_KEY="$(tr -d '\r' < "$KEY_FILE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  fi
  if [[ -z "${EVREN_LLM_API_KEY:-}" ]]; then
    fail "Kayitli API anahtari bulunamadi ($KEY_FILE yok). Once kurulumu calistirin."
  fi
  export EVREN_LLM_API_KEY

  models_raw="$(fetch_models_json "$EVREN_LLM_API_KEY")" \
    || fail "Model listesi alinamadi (API erisilemez). Internet baglantinizi ve anahtarinizi kontrol edin."
  MODELS_MAP_JSON="$(printf '%s' "$models_raw" | build_models_map)" \
    || fail "Model listesi islenemedi."
  [[ -n "${MODELS_MAP_JSON:-}" ]] || fail "Model listesi bos dondu."

  mkdir -p "$CONFIG_DIR"
  backup_config

  if [[ "$json_tool" == "python3" ]]; then
    merge_config_python
  else
    merge_config_jq
  fi

  chmod 600 "$KEY_FILE" 2>/dev/null || true

  printf '\n'
  ok "Model listesi API ile senkronize edildi. Diger provider/ayarlar korundu."
  exit 0
fi

if [[ -n "${1:-}" && "${1:-}" != "--uninstall" ]]; then
  fail "Bilinmeyen parametre: $1 (desteklenenler: --sync-models, --uninstall)"
fi

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

  # Shell RC dosyalarından EVREN_LLM_API_KEY satırlarını sil
  remove_env_from_rc

  # Anahtar dosyasini sil
  if [[ -f "$KEY_FILE" ]]; then
    rm -f "$KEY_FILE"
    ok ".evren-key dosyasi silindi ($KEY_FILE)."
  else
    info ".evren-key dosyasi zaten yok."
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

# 1a) Anahtari dosya referansi icin .evren-key'e yaz (GUI/IDE/desktop icin esas cozum)
mkdir -p "$CONFIG_DIR"
printf '%s' "$EVREN_LLM_API_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
ok "API anahtari $KEY_FILE dosyasina yazildi (chmod 600)."

# 1b) Shell RC dosyalarına kalıcı olarak yaz (terminal + dogrudan curl kullanimi icin)
write_env_to_rc

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

# ── 4) Model listesini API'den cek ───────────────────────────────────────────

models_raw=""
if models_raw="$(fetch_models_json "$EVREN_LLM_API_KEY")" && \
   MODELS_MAP_JSON="$(printf '%s' "$models_raw" | build_models_map)" && \
   [[ -n "${MODELS_MAP_JSON:-}" ]]; then
  ok "Model listesi API'den alindi."
else
  warn "Model listesi API'den alinamadi; son bilinen liste kullanilacak."
  MODELS_MAP_JSON="$(printf '%s' "$FALLBACK_MODELS_JSON" | build_models_map)" \
    || fail "Yedek model listesi islenemedi."
fi
[[ -n "${MODELS_MAP_JSON:-}" ]] || fail "Model listesi olusturulamadi."

# ── 5) opencode.jsonc merge ──────────────────────────────────────────────────

mkdir -p "$CONFIG_DIR"
backup_config

if [[ "$json_tool" == "python3" ]]; then
  merge_config_python
else
  merge_config_jq
fi

chmod 600 "$KEY_FILE" 2>/dev/null || true

# ── 6) OpenCode doğrulaması ──────────────────────────────────────────────────
# NOT: config artik {file:...} referansi kullandigi icin dogrulama env olmadan
# da gecmelidir (GUI/IDE senaryosu). Env'i bilerek bosaltarak test et.

if command -v opencode >/dev/null 2>&1; then
  printf '\n=== opencode models ===\n'
  opencode models || fail "opencode models komutu basarisiz oldu."
  printf '\n--- env olmadan tekrar test (GUI/IDE simulasyonu) ---\n'
  if env -u EVREN_LLM_API_KEY opencode models >/dev/null 2>&1; then
    ok "Dosya referansi dogrulandi: env olmadan da calisiyor."
  else
    warn "env olmadan calisma testi basarisiz; .evren-key dosyasini kontrol edin."
  fi
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

printf '\nNot: opencode artik anahtari %s dosyasindan okur; terminali yeniden baslatmaya gerek yoktur.\n' "$KEY_FILE"
printf 'Terminalde dogrudan curl icin env degiskeni de yazildi; yeni terminalde gecerli olur.\n'
printf '\nRate-limit notu: EVREN API yogun istekte "5 saniye sonra tekrar deneyin" donebilir.\n'
printf 'opencode ile tek gorev calistirin, paralel ajanlardan kacin; 429 alirsaniz kisa bekleyip tekrar deneyin.\n'
