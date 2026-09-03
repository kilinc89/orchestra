# Orchestra

Claude orkestre eder. GPT-5.6 ailesi ve Gemini worker olarak çalışır.

Claude planlar, işi böler, worker'ları paralel çalıştırır, kanıt toplar, doğrular
ve kabul kriteri geçene kadar döngüye sokar. Claude worker grafiğinin içinde
değildir — kod yazmaz, orkestre eder.

## Worker'lar

İki CLI, ikisi de kendi girişini taşır — **harici sağlayıcı yok, API key yok.**

| Worker | Model | CLI | Rol | Durum |
|---|---|---|---|---|
| `luna` | `gpt-5.6-luna` | codex | döngü, yüksek hacim, hızlı | ✅ canlı doğrulandı |
| `terra` | `gpt-5.6-terra` | codex | implementasyon | ✅ canlı doğrulandı |
| `sol` | `gpt-5.6-sol` | codex | zor problem, son doğrulama | ✅ canlı doğrulandı |
| `gemini` | `gemini-3.1-pro-high` | agy | bağımsız inceleme | ⚠️ adaptör hazır, print mode timeout |
| `gemini-flash` | `gemini-3.8-flash-medium` | agy | hızlı ikinci göz | ⚠️ aynı |
| `gpt55` | `gpt-5.5` | codex | regresyon karşılaştırma | kapalı |
| `sonnet` | `claude-sonnet-4-6` | agy | üçüncü bağımsız göz | kapalı |

Model ID'leri uydurulmadı: `~/.codex/models_cache.json` ve `agy models` çıktısından
alındı; `codex` tarafındakilerin **hepsi canlı çalıştırılarak** doğrulandı.

## İki engine

| Engine | CLI | Çıktı | Auth |
|---|---|---|---|
| `codex` | OpenAI Codex CLI | JSONL event akışı | ChatGPT girişi (`codex login`) |
| `agy` | Antigravity CLI | tek JSON nesnesi | kendi girişi (`~/.antigravity`) |

Her ikisi de gerçek agentic runtime: dosya okur/yazar, komut çalıştırır, test koşar.
Orchestra ikisini tek bir `result.json` şemasına normalize eder.

## Kurulum

```bash
./install.sh --dry-run          # ne yapacağını göster, hiçbir şey yaratma
./install.sh --copy             # ~/.claude/skills/orchestra altına kur
./scripts/orchestra.sh preflight
```

Ek yapılandırma gerekmez — her iki CLI'nin mevcut girişi kullanılır.
Tek koşul `codex-cli >= 0.153.0`; eski sürüm `gpt-5.6-*` için API 400 döner.

## Kullanım

```bash
# worker durumu — CAGRILABILIR sütunu gerçek kontroldür, iddia değil
scripts/orchestra.sh workers

# görev grafiği çalıştır
scripts/orchestra.sh run --tasks tasks.json --workspace ~/proje \
  --accept "npm test" --max-iter 3

# tek worker'ı bir koşula kadar döndür
scripts/orchestra.sh loop --worker luna \
  --prompt "Tüm testleri geçir" --until "npm test" --max-iter 5
```

`tasks.json`:

```json
{
  "objective": "Hedef",
  "tasks": [
    {"id": "impl", "worker": "terra", "prompt": "..."},
    {"id": "loop", "worker": "luna",  "prompt": "..."}
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

46 test. Script'ler sahte bir `codex` ve sahte bir `agy` ile **gerçekten
çalıştırılır** — "dosya var mı" kontrolü değil, davranış testi. Sahte engine'ler
gerçeklerinin kritik davranışını taklit eder (hata durumunda exit 0, stderr sızıntısı,
boş çıktı, aralıklı hata). Bu paket geliştirme sırasında 8 gerçek bug yakaladı.

## Canlı doğrulama

Uçtan uca, gerçek worker'larla (stub değil):

| Koşu | Sonuç |
|---|---|
| Tek worker: `terra` bozuk `to_roman()`'ı düzeltti | 46s, 1 iterasyon, 12/12 test geçti |
| Paralel: `terra` + `luna` iki ayrı dosyada | 24.5s duvar saati (ardışık 45s olurdu) |
| Dosya sahipliği | Worker'lar yalnızca kendi dosyalarına yazdı, çakışma yok |
| Bağımsız kontrol | Testler orkestratöre değil, elle çalıştırılarak doğrulandı |

## Bilinen durum

- `agy` print mode bu makinede timeout veriyor (`num_turns: 0`, `"timeout waiting
  for response"`). 4 varyantta denendi: 90s / 300s / `--new-project` / modelsiz
  minimal çağrı. `agy models` çalışıyor, yani API erişilebilir ama agent turn'ü
  hiç başlamıyor. Adaptör yazıldı ve stub'la test edildi; **canlı doğrulanmadı.**
  Düzelene kadar bağımsız inceleme için `sol` kullanılabilir (aynı aile olduğu
  için gerçek bağımsızlık sağlamaz — bu bilinçli bir taviz).
- `codex-cli` en az 0.153.0 olmalı. Eski sürüm `gpt-5.6-*` için
  `"requires a newer version of Codex"` (API 400) döndürür.
- Yalnızca `codex` ve `agy` kullanılır. Harici sağlayıcı, proxy ya da API key
  yolu bilinçli olarak yoktur; test 16 bunun kodda kalmadığını denetler.
