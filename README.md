# Orchestra

Claude orkestre eder. GPT-5.6 ailesi ve Gemini worker olarak çalışır.

Claude planlar, işi böler, worker'ları paralel çalıştırır, kanıt toplar, doğrular
ve kabul kriteri geçene kadar döngüye sokar. Claude worker grafiğinin içinde
değildir — kod yazmaz, orkestre eder.

## Worker'lar

Üç yerel CLI, üçü de kendi girişini taşır — **harici sağlayıcı yok, API key yok.**

| Worker | Model | CLI | Rol | Canlı |
|---|---|---|---|---|
| `composer` | `composer-2.5` | agent | döngü, yüksek hacim | ✅ 6s |
| `codex53` | `gpt-5.3-codex-high` | agent | implementasyon (varsayılan) | ✅ 7s |
| `luna` | `gpt-5.6-luna-high` | agent | implementasyon (alt) | ✅ 7s |
| `gemini` | `gemini-3.7-flash-high` | agent | inceleme — Google ailesi | ✅ 9s |
| `sonnet` | `claude-sonnet-5-thinking-high` | agent | inceleme — Anthropic | ✅ 7s |
| `opus` | `claude-opus-5-high` | agent | en güçlü inceleyici | ✅ 9s |
| `sol` | `gpt-5.6-sol-high` | agent | zor problem, son doğrulama | ✅ 8s |
| `terra-codex` | `gpt-5.6-terra` | codex | implementasyon | ⚠️ backend 404 |
| `fable`, `grok`, `sol-codex`, `gemini-agy` | — | — | yedek | kapalı |

Model ID'leri uydurulmadı: `agent --list-models`, `~/.codex/models_cache.json` ve
`agy models` çıktılarından alındı; `enabled` olanların **hepsi canlı çalıştırılarak**
doğrulandı. Süreler gerçek ölçüm.

`fable` bilinçli kapalı: Cursor onu "NO ZDR" olarak işaretliyor (veri saklama
politikası farklı). `grok` bu hesapta boş yanıt dönüyor.

## Üç engine

| Engine | CLI | Çıktı | Auth |
|---|---|---|---|
| `agent` | Cursor Agent | tek JSON nesnesi (`is_error`) | `~/.cursor` |
| `codex` | OpenAI Codex CLI | JSONL event akışı | ChatGPT (`codex login`) |
| `agy` | Antigravity CLI | tek JSON nesnesi | `~/.antigravity` |

Engine adı = binary adı. Test 21 route/dispatch uyuşmazlığını denetler
(bu gerçek bir bug'dı: route'ta `agent`, dispatch'te `cursor` yazıyordu).

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
# config kontrolü: kim tanımlı ve yapılandırılmış
scripts/orchestra.sh workers

# GERÇEK kontrol: her worker'a canlı ping atar, çalışanı kanıtlar (ücret harcar)
scripts/orchestra.sh doctor

# görev grafiği çalıştır
scripts/orchestra.sh run --tasks tasks.json --workspace ~/proje \
  --accept "npm test" --max-iter 3

# tek worker'ı bir koşula kadar döndür
scripts/orchestra.sh loop --worker composer \
  --prompt "Tüm testleri geçir" --until "npm test" --max-iter 5
```

`tasks.json`:

```json
{
  "objective": "Hedef",
  "tasks": [
    {"id": "impl", "worker": "codex53", "prompt": "..."},
    {"id": "rev",  "worker": "opus",    "prompt": "..."}
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

60 test. Script'ler sahte bir `codex` ve sahte bir `agy` ile **gerçekten
çalıştırılır** — "dosya var mı" kontrolü değil, davranış testi. Sahte engine'ler
gerçeklerinin kritik davranışını taklit eder (hata durumunda exit 0, stderr sızıntısı,
boş çıktı, aralıklı hata). Bu paket geliştirme sırasında 8 gerçek bug yakaladı.

## Canlı doğrulama

Gerçek worker'larla, stub değil:

| Koşu | Sonuç |
|---|---|
| `doctor` — 7 worker'a canlı ping | 5 cursor worker'ı CALISIR (6-9s), 2 codex worker'ı KIRIK (404) |
| `codex53` bozuk `Account` sınıfını düzeltti | 30s, 1 iterasyon, testler geçti |
| `gemini` + `opus` paralel bağımsız inceleme | 48.7s duvar saati (ardışık 79s olurdu) |
| Dosya sahipliği | Worker'lar yalnızca kendi dosyalarına yazdı |

### Bağımsız incelemenin işe yaradığı an

`codex53` implementasyonu yaptı, **testlerin hepsi geçti**. Ardından iki farklı
model ailesi kodu inceledi ve ikisi de aynı kritik açığı buldu:

```python
a = Account(100)
a.withdraw(-100)   # -> 200   para çekerek bakiye ARTIYOR
```

Uygulayıcı da, test paketi de bunu kaçırmıştı. `opus` ayrıca `float` ile para
tutmanın yuvarlama hatasını ve kilitsiz okuma-değiştirme-yazma dizisindeki
race condition'ı raporladı.

Bu yüzden `SKILL.md` uygulayan ile inceleyenin **farklı model ailesinden**
olmasını şart koşuyor. Aynı aileyle incelettiğinde bu bulgular çıkmayabilir.

## Bilinen durum

- `codex` native yolu **şu an 404 veriyor**: `wss://chatgpt.com/backend-api/codex/responses`.
  Aynı sürüm ve token'la daha önce çalıştı; `codex login` ile oturum tazelenmeli.
  `doctor` bunu KIRIK olarak raporlar — `workers` (yalnızca config kontrolü) `ok` der.
- `agy` print mode bu makinede timeout veriyor (`num_turns: 0`, `"timeout waiting
  for response"`). 4 varyantta denendi: 90s / 300s / `--new-project` / modelsiz
  minimal çağrı. `agy models` çalışıyor, yani API erişilebilir ama agent turn'ü
  hiç başlamıyor. Adaptör yazıldı ve stub'la test edildi; **canlı doğrulanmadı.**
  Düzelene kadar bağımsız inceleme için `sol` kullanılabilir (aynı aile olduğu
  için gerçek bağımsızlık sağlamaz — bu bilinçli bir taviz).
- `codex-cli` en az 0.153.0 olmalı. Eski sürüm `gpt-5.6-*` için
  `"requires a newer version of Codex"` (API 400) döndürür.
- Yalnızca yerel CLI'lar kullanılır (`agent`, `codex`, `agy`). Harici sağlayıcı,
  proxy ya da API key yolu bilinçli olarak yoktur; test 16 bunu denetler.
