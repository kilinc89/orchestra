# Orchestra

Claude orkestre eder. DeepSeek, GPT ve Gemini worker olarak çalışır.

Claude planlar, işi böler, worker'ları paralel çalıştırır, kanıt toplar, doğrular
ve kabul kriteri geçene kadar döngüye sokar. Claude worker grafiğinin içinde
değildir — kod yazmaz, orkestre eder.

## Worker'lar

| Worker | Model | Yol | Rol | $/M in-out |
|---|---|---|---|---|
| `deepseek` | `deepseek/deepseek-v4-flash-0731` | OpenRouter | döngü, yüksek hacim | 0.065 / 0.18 |
| `gpt` | `openai/gpt-5.6-luna` | OpenRouter | implementasyon | 0.20 / 1.20 |
| `gemini` | `gemini-3.1-pro-high` | agy | bağımsız inceleme | abonelik |
| `gemini-flash` | `gemini-3.8-flash-medium` | agy | hızlı kontrol | abonelik |
| `gpt-native` | `gpt-5.6-luna` | codex OAuth | implementasyon | abonelik |
| `gemini-or`, `sonnet-agy` | — | yedek | inceleme | — |

Model ID'leri uydurulmadı: OpenRouter `/api/v1/models` ve `agy models` çıktısından
2026-09-03'te doğrulandı. `gpt-native` ve yedekler `enabled: false` — çalışır hale
gelince `workers.json` içinde açılır.

## İki engine

| Engine | CLI | Çıktı | Kullanan yollar |
|---|---|---|---|
| `codex` | OpenAI Codex CLI | JSONL event akışı | `openrouter`, `native` |
| `agy` | Antigravity CLI | tek JSON nesnesi | `agy` |

Her ikisi de gerçek agentic runtime: dosya okur/yazar, komut çalıştırır, test koşar.
Orchestra ikisini tek bir `result.json` şemasına normalize eder.

## Kurulum

```bash
./install.sh --dry-run          # ne yapacağını göster, hiçbir şey yaratma
./install.sh --copy             # ~/.claude/skills/orchestra altına kur
./scripts/orchestra.sh preflight
```

OpenRouter worker'ları için tek gereken:

```bash
export OPENROUTER_API_KEY='...'   # openrouter.ai/keys
```

## Kullanım

```bash
# worker durumu — CAGRILABILIR sütunu gerçek kontroldür, iddia değil
scripts/orchestra.sh workers

# görev grafiği çalıştır
scripts/orchestra.sh run --tasks tasks.json --workspace ~/proje \
  --accept "npm test" --max-iter 3

# tek worker'ı bir koşula kadar döndür
scripts/orchestra.sh loop --worker deepseek \
  --prompt "Tüm testleri geçir" --until "npm test" --max-iter 5
```

`tasks.json`:

```json
{
  "objective": "Hedef",
  "tasks": [
    {"id": "impl", "worker": "gpt",      "prompt": "..."},
    {"id": "rev",  "worker": "gemini",   "prompt": "..."}
  ]
}
```

Aynı turdaki görevler paralel çalışır (varsayılan 4 eşzamanlı).

## Kanıt

Her koşu `<workspace>/.orchestra/runs/<id>/` altına yazar:

```
iter-1/<task>/
├── prompt.txt     worker'a ne gönderildi
├── last.txt       worker çıktısı (SADECE çıktı)
├── stderr.log     hata akışı, çıktıyla asla karışmaz
├── raw.out        ham engine akışı
├── usage.json     token kullanımı (agy)
└── result.json    normalize sonuç
```

`result.json` içinde `model_requested` ve `model_verified` ayrı alanlardır.
Doğrulanamıyorsa `unverified` yazar — hangi modelin çalıştığı asla uydurulmaz.

## Tasarım kararları

Bunlar rastgele değil; benzer bir projeyi inceleyip hatalarından çıkarıldı.

1. **Exit koduna güvenilmez.** `codex exec`, API 400 alıp `turn.failed` yazdığında
   bile exit 0 döner. `agy` timeout'ta `status: ERROR` yazar. Başarı daima
   çıktıdan çıkarılır, exit kodundan değil. (Test 3, 12)
2. **stderr çıktıyla birleştirilmez.** `2>&1` yok. Hata mesajı worker'ın işi
   gibi görünmez. (Test 3, 12)
3. **Model uydurulmaz.** Çalışan model event akışından doğrulanır; bulunamazsa
   `unverified`. "X modeli konuştu" diye etiketlenip aslında Y'nin çalışması
   mümkün değil. (Test 2, 5, 11)
4. **Çağrılabilirlik prose değil kod.** `worker_callable` binary'yi, auth'u ve
   anahtarı gerçekten kontrol eder. Anahtar yoksa `unavailable` döner, sessizce
   başka modele geçmez. (Test 5)
5. **bash 3.2 uyumlu.** macOS varsayılanı bash 3.2'dir. Associative array,
   `mapfile`, `${v,,}`, `wait -n` kullanılmaz; boş dizi genişletmesi
   `set -u` altında patlamayacak şekilde yazılır. Testler `/bin/bash` ile koşar. (Test 1)
6. **Kişisel mutlak yol gömülmez.** Yollar `BASH_SOURCE` üzerinden çözülür,
   test bunu denetler. (Test 10)
7. **Sınırsız döngü yoktur.** `--max-iter` zorunlu üst sınır. Sınır dolarsa
   `status: exhausted` döner, başarı gibi raporlanmaz. (Test 8)
8. **Kendi çıktısı workspace'i kirletmez.** `.orchestra/` `.git/info/exclude`'a
   eklenir (kullanıcının `.gitignore`'u ellenmez), yoksa ikinci koşu daima
   "kirli workspace" diye reddedilirdi. (Test 15)

## Güvenlik

Worker'lar `danger-full-access` ile çalışır: sandbox yok, onay sorulmaz.
Bu bilinçli bir tercih, ama korumasız değil — `run`, temiz bir git deposu ister
ve kirli ya da versiyonsuz workspace'te başlamayı **reddeder**. `--force` bunu aşar.

Geri alma tek komut: `git checkout .`

## Test

```bash
tests/test_orchestra.sh
```

41 test. Script'ler sahte bir `codex` ve sahte bir `agy` ile **gerçekten
çalıştırılır** — "dosya var mı" kontrolü değil, davranış testi. Sahte engine'ler
gerçeklerinin kritik davranışını taklit eder (hata durumunda exit 0, stderr sızıntısı,
boş çıktı, aralıklı hata). Bu paket geliştirme sırasında 8 gerçek bug yakaladı.

## Bilinen durum

- `agy` print mode bu makinede timeout veriyor (`num_turns: 0`) — adaptör
  yazıldı ve test edildi, ancak canlı doğrulama yapılamadı.
- `codex-cli 0.142.0` native `gpt-5.6-luna` için eski (API 400 "requires a newer
  version"). `codex update` sonrası `gpt-native` açılabilir. OpenRouter yolu
  bu sorundan etkilenmez.
