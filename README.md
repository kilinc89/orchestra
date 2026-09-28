# Orchestra

Claude orkestre eder. İki skill vardır:

| Skill | Havuz | Jev eşiği |
|---|---|---|
| `orchestra` | Yalnızca Claude Code alt ajanları: `claude-haiku`, `claude-sonnet`, `claude-opus` | 0.5 |
| `orchestrag` (OrchestraG) | Alt ajanlar + GPT-5.6 ailesi, Gemini, Composer ve Cursor üzerinden Claude worker'ları | 0.4 |

Hangi işin kime gideceğini TypeSafe Jev seçer (bkz. [Jev yönlendirici](#jev-yönlendirici)).

İki skill'de de orkestratör modeli **Claude Opus 5.5** (`claude-opus-5-5`), `medium` effort
ile sabitlenmiştir: `SKILL.md` frontmatter'ındaki `model:` ve `effort:` alanları, skill
çalıştığı sürece oturumu bu modele ve seviyeye geçirir. Worker modelleri bundan
etkilenmez; onlar `workers.json`'dan gelir.

Alt ajanlar `workers.json` → `subagents` altında kayıtlıdır. CLI'dan geçmezler:
orkestratör onları `Agent(subagent_type: "general-purpose", model: "haiku"|"sonnet"|"opus")`
ile çalıştırır. Bu yüzden `run`, alt ajana atanmış görevi reddeder.

Claude planlar, işi böler, worker'ları paralel çalıştırır, kanıt toplar, doğrular
ve kabul kriteri geçene kadar döngüye sokar. Claude worker grafiğinin içinde
değildir — kod yazmaz, orkestre eder.

## Worker'lar

Üç yerel CLI; üçü de kendi girişini kullanır, ek yapılandırma istemez.

| Worker | Model | CLI | Rol | Canlı |
|---|---|---|---|---|
| `gemini-agy` | `gemini-3.8-flash-high` | agy | inceleme — Google ailesi | ✅ 1.5s |
| `composer` | `composer-2.5` | agent | döngü, yüksek hacim | ✅ 6s |
| `codex53` | `gpt-5.3-codex-high` | agent | implementasyon (varsayılan) | ⚠️ Cursor kotası |
| `luna` | `gpt-5.6-luna-high` | agent | implementasyon (alt) | ⚠️ Cursor kotası |
| `gemini` | `gemini-3.7-flash-high` | agent | inceleme — Google ailesi | ⚠️ Cursor kotası |
| `sonnet` | `claude-sonnet-5-thinking-high` | agent | inceleme — Anthropic | ⚠️ Cursor kotası |
| `opus` | `claude-opus-5-high` | agent | en güçlü inceleyici | ⚠️ Cursor kotası |
| `sol` | `gpt-5.6-sol-high` | agent | zor problem, son doğrulama | ⚠️ Cursor kotası |
| `terra-codex` | `gpt-5.6-terra` | codex | implementasyon | ⚠️ backend 404 |
| `fable`, `grok`, `sol-codex` | — | — | yedek | kapalı |

### Gemini alt ajanı

Görev grafiği kurmadan hızlı bir ikinci göz gerektiğinde `.claude/agents/gemini.md`
alt ajanı kullanılır:

```
Agent(subagent_type: "gemini", prompt: "Şu diff'i güvenlik açısından incele: ...")
```

Alt ajan bir boru hattıdır: bağlamı toplar, `agy --print ... --model
gemini-3.8-flash-high --output-format json` çağırır ve `.response` alanını
kısaltmadan geri verir. Alt ajanın **kendisi bir Claude modelidir**; Gemini yalnızca
o `agy` çağrısında devreye girer — bu yüzden Gemini'ye hiç gitmeden üretilmiş bir
cevabı "Gemini dedi ki" diye etiketlemez. `agy` JSON'u çalışan modeli döndürmediği
için model **istendi** denir, **doğrulandı** denmez.

Varsayılan çağrıda `--dangerously-skip-permissions` yoktur: bu bir inceleme yoludur,
yazma yolu değil.

`install.sh` bu tanımı `~/.claude/agents/` altına kopyalar, böylece her projeden
çağrılabilir. `--no-agents` bunu atlar.

Model ID'leri uydurulmadı: `agent --list-models`, `~/.codex/models_cache.json` ve
`agy models` çıktılarından alındı; `enabled` olanların **hepsi canlı çalıştırılarak**
doğrulandı. Süreler gerçek ölçüm.

`fable` bilinçli kapalı: Cursor onu "NO ZDR" olarak işaretliyor (veri saklama
politikası farklı). `grok` bu hesapta boş yanıt dönüyor.

**2026-09-06 durumu.** Cursor hesabının kotası doldu; `composer-2.5` dışındaki her
cursor worker'ı `ActionRequiredError: You're out of usage` veriyor. Aynı gün
Antigravity CLI 1.1.27 ile `agy` print mode düzeldi (eskiden `num_turns=0` ile
timeout veriyordu), böylece `gemini-agy` açıldı ve canlı doğrulandı — şu an
çalışan tek Google yolu odur. Homebrew'daki bağımsız `gemini` CLI'ı ise Google
kapattı: `IneligibleTierError — This client is no longer supported... migrate to
the Antigravity suite`. Yani Gemini'ye tek giriş `agy`.

## Üç engine

| Engine | CLI | Çıktı | Auth |
|---|---|---|---|
| `agent` | Cursor Agent | tek JSON nesnesi (`is_error`) | `~/.cursor` |
| `codex` | OpenAI Codex CLI | JSONL event akışı | ChatGPT (`codex login`) |
| `agy` | Antigravity CLI | tek JSON nesnesi | `~/.antigravity` |

Engine adı = binary adı. Test 21 route/dispatch uyuşmazlığını denetler
(bu gerçek bir bug'dı: route'ta `agent`, dispatch'te `cursor` yazıyordu).

Üçü de gerçek agentic runtime: dosya okur/yazar, komut çalıştırır, test koşar.
Orchestra üçünü tek bir `result.json` şemasına normalize eder.

## Repo düzeni

```text
.
├── .claude
│   └── agents
│       └── gemini.md           Gemini alt ajanının tanımıdır; işi `agy` üzerinden Gemini'ye devreder.
├── .gitignore                  .orchestra/ ve yerel geçici dosyaları gitten dışlar.
├── README.md                   Projeyi, tasarım kararlarını ve canlı durum notlarını belgeler.
├── SKILL.md                    Orchestra: yalnızca Claude alt ajanlarıyla çalışan protokol.
├── install.sh                  Skill'leri ~/.claude/skills/orchestra ve orchestrag, alt ajanları ~/.claude/agents altına kurar.
├── scripts
│   ├── dispatch.sh             Tek worker çağrısı yapar ve sonucu normalize `result.json` olarak yazar.
│   ├── jev.sh                  Jev yönlendiricisi: görevi hangi worker'ın alacağını TypeSafe Jev'e sorar, anahtarı Keychain'de tutar.
│   ├── lib.sh                  Ortak yardımcı fonksiyonlar ve worker çağrılabilirlik kontrollerini tutar.
│   └── orchestra.sh            preflight/workers/doctor/run/loop/route/jev-key/health/schedule alt komutlarını yöneten ana CLI'dir.
├── skills
│   └── orchestrag
│       └── SKILL.md            OrchestraG: alt ajanlar + GPT/Gemini CLI worker'larıyla çalışan protokol.
├── tasks.example.json          Görev grafi biçimi için örnek `tasks.json` dosyasıdır.
├── tests
│   ├── check_readme.sh         README'yi workers.json ve gerçek test sayısına karşı denetleyen kabul kriteridir.
│   ├── fixture-workers.json    Testler için izole route/worker konfigürasyonunu sağlar.
│   ├── stub
│   │   ├── agent               Sahte Cursor Agent çıktısı üreten, üç sahte engine'den biri olan stub'dır.
│   │   ├── agy                 Sahte Antigravity (agy) çıktıları üreten stub'dır.
│   │   ├── codex               Sahte Codex JSONL akışlarını üreten stub'dır.
│   │   ├── launchctl           Sahte launchctl; zamanlayıcı testleri gerçek launchd'ye dokunmaz.
│   │   └── curl                Sahte TypeSafe yanıtı üreten stub'dır; Jev yönlendiricisinin testleri içindir.
│   └── test_orchestra.sh       Üç engine davranışını ve döngü mantığını uçtan uca test eder.
└── workers.json                Route, worker, model ve rol eşleşmelerinin kayıt dosyasıdır.
```

## Kurulum

```bash
./install.sh --dry-run          # ne yapacağını göster, hiçbir şey yaratma
./install.sh --copy             # ~/.claude/skills/orchestra ve orchestrag altına kur
./scripts/orchestra.sh preflight
```

Worker'lar için ek yapılandırma gerekmez — her üç CLI'nin mevcut girişi kullanılır.
Tek istisna isteğe bağlı Jev yönlendiricisidir; o bir TypeSafe anahtarı ister
(bkz. [Jev yönlendirici](#jev-yönlendirici)).
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

## Jev yönlendirici

Hangi işin hangi worker'a gideceğini [TypeSafe Jev](https://docs.typesafe.ai/introduction)
seçer. Jev bir System One modelidir: metin üretmez, kod yazmaz. Bir **Choice**
sorusuna seçim, her seçenek için olasılık ve bir `confidence` döndürür. Bu yüzden
worker değil, **yönlendiricidir**.

Her görev için sırayla iki atomik soru sorulur:

1. `role`: iş ne tür? (`loop` / `implement` / `review`)
2. `worker`: yalnızca **o roldeki** adaylar arasından hangisi? Rolde tek aday
   varsa bu soru sorulmaz.

İkinci sorunun yalnızca o roldeki adayları görmesi bilinçli bir tercih. İlk
sürümde iki soru tek istekte ve tüm adaylar üzerinden soruluyordu. Canlı denemede
Jev işin türünü 0.97 güvenle bildi, ama benzer worker'lar olasılığı bölüştüğü
için worker güveni 0.40'ta kaldı ve atama yapılmadı.

Adaylar havuza göre belirlenir (`--pool`):

- `claude`: `workers.json` → `subagents` (Orchestra).
- `all` (varsayılan): alt ajanlar + **çağrılabilir** CLI worker'ları (OrchestraG).

Her iki cevap da havuzun eşiğinin üstündeyse atama yapılır (`jev.min_confidence`:
`claude` 0.5, `all` 0.4). Aksi hâlde görev `"auto"` kalır, sebep `routing.status`
(`low_confidence`, `error`) ve `routing.stage` (`role` / `worker`) alanlarına
yazılır ve çıkış kodu 2 olur. Bu durumda karar orkestratöre kalır. `run`, `"auto"`
görev içeren dosyayı çalıştırmayı reddeder.

Canlı deneme (2026-09-28, `jev-1.13.0`), altı yönlendirmenin altısı da atandı:

| Görev | `--pool claude` | `--pool all` |
|---|---|---|
| `parseConfig()` implemente et | `claude-sonnet` 0.94 | `codex53` 0.56 |
| Diff'i güvenlik açısından incele | `claude-opus` 1.00 | `claude-opus` 0.91 |
| `var` → `const`, testler geçene kadar | `claude-haiku` 0.53 | `composer` 0.84 |

```bash
# anahtarı bir kez kaydet (panodan; sohbete yapıştırma)
pbpaste | scripts/orchestra.sh jev-key set
scripts/orchestra.sh jev-key status      # kaynak + son 4 karakter

# tek soru
scripts/orchestra.sh route --pool claude --prompt "parser.ts için birim testleri yaz"

# görev dosyasındaki "worker": "auto" görevlerini ata
scripts/orchestra.sh route --pool all --tasks tasks.json --out tasks.routed.json
scripts/orchestra.sh run --tasks tasks.routed.json --workspace ~/proje --accept "npm test"
```

```json
{"id": "rev", "worker": "auto", "exclude": ["codex53", "luna"], "prompt": "..."}
```

`exclude`, uygulayanla aynı aileden bir inceleyici seçilmesini engellemek içindir.
Jev aile kuralını bilmez; o kuralı orkestratör uygular.

Atanan her görevde `routing` alanı kanıt olarak durur: `worker`, `kind`
(`subagent` / `worker`), `model`, `pool`, `confidence`, `probabilities`, `role`,
`role_confidence`, `min_confidence`, `jev_model`. `kind: subagent` olan görevler
`Agent` tool ile, diğerleri `run` ile çalıştırılır.

**Kota ve sağlık kontrolü.** `route --pool all` kotası dolmuş worker'ı seçmez:

- `scripts/orchestra.sh health` her etkin CLI worker'a **paralel** canlı ping atar
  ve sonucu `~/.cache/orchestra/health.json`'a yazar. Durumlar: `ok`, `quota`
  (hata metni `out of usage` / `ActionRequiredError` / `quota` / `rate limit` / 429
  içeriyor), `broken` (başka hata ya da `ping_timeout_sec` zaman aşımı), `unavailable`.
- `quota` ve `broken` worker'lar Jev'e **aday olarak hiç gösterilmez**. Dışarıda
  kalanlar kararın `unhealthy_excluded` alanına, önbelleğin yaşı `health_age_sec`
  alanına yazılır.
- `scripts/orchestra.sh schedule install` bir macOS LaunchAgent kurar
  (`com.orchestra.health`), bu da `health`'i **4 saatte bir** çalıştırır (`interval_sec`).
  Log `~/.cache/orchestra/health.log` dosyasına gider. `schedule status` durumu ve
  son kontrolü gösterir; `schedule remove` kaldırır.
- Zamanlayıcı çalışmasa bile eski veriyle seçim yapılmaz: önbellek 4 saatten eskiyse
  `route --pool all` seçimden önce `health`'i kendisi çalıştırır.
  `ORCHESTRA_HEALTH_AUTO=0` bunu kapatır.
- Kota yenilenince worker bir sonraki kontrolde kendiliğinden geri gelir; kalıcı
  bir "kırık" listesi tutulmaz.
- Ping gerçek bir çağrıdır, kota harcar. Sıklık `workers.json` → `health` bloğundan
  (`interval_sec`, `ping_timeout_sec`) ayarlanır.
- `--pool claude` ping atmaz, çünkü o havuzda CLI worker'ı yok.

**Anahtarın saklanması.** Okuma sırası: `TYPESAFE_API_KEY` ortam değişkeni, sonra
macOS Keychain (servis `orchestra-typesafe`), sonra `~/.config/orchestra/typesafe.key`
(0600, Keychain olmayan sistemler için). Anahtar Keychain'e ve curl'e stdin
üzerinden verilir, yani `ps` çıktısında görünmez. Repoya, `workers.json`'a, log'a
ya da koşu dizinine yazılmaz. `jev-key delete` siler.

Ayarlar `workers.json` içindeki `jev` bloğundadır: `url`, `model` (`jev-latest`),
`min_confidence` (havuz başına), `timeout_sec`.

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
4. **Çağrılabilirlik prose değil kod.** `worker_callable`, worker'ın kayıtlı ve
   etkin olduğunu, route'un tanımlı olduğunu, engine binary'sinin PATH'te
   bulunduğunu ve route'a göre giriş izinin mevcut olduğunu denetler (`codex`:
   `~/.codex/auth.json`, `agy`: `~/.antigravity`, `cursor`: `~/.cursor`).
   Koşul sağlanmazsa `unavailable` döner, sessizce başka modele geçmez. (Test 5)
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

130 test. Script'ler sahte bir `codex`, sahte bir `agy` ve sahte bir `agent` ile **gerçekten
çalıştırılır** — "dosya var mı" kontrolü değil, davranış testi. Sahte engine'ler
gerçeklerinin kritik davranışını taklit eder (hata durumunda exit 0, stderr sızıntısı,
boş çıktı, aralıklı hata). Bu paket geliştirme sırasında 8 gerçek bug yakaladı.

`tests/check_readme.sh`, README'yi iddia degil olcumle denetleyen kabul kriteridir:
enabled worker/model/engine kayitlarini `workers.json` ile, "130 test" ifadesini ise
`tests/test_orchestra.sh` icinden hesaplanan gercek sayi ile karsilastirir.
Bu denetim `run --accept` ile dogrudan kullanilir:

```bash
scripts/orchestra.sh run --tasks tasks.json --workspace ~/proje \
  --accept "bash tests/check_readme.sh" --max-iter 3
```

Test paketi uc sahte engine ile calisir: `tests/stub/codex`, `tests/stub/agy` ve
`tests/stub/agent` (Cursor Agent davranisini taklit eden stub). Jev yonlendiricisi
`tests/stub/curl` ile test edilir: iki asamali soru, havuzlar ve esikleri, dusuk guven,
HTTP 401 ve anahtarin argv'ye, ciktiya ya da log'a sizmadigi. Saglik kontrolu sahte
`agent`'in `quota` ve `hang` modlariyla, zamanlayici `tests/stub/launchctl` ile test
edilir; testler gercek `~/.cache` ve `~/Library/LaunchAgents` dizinlerine yazmaz.

## Canlı doğrulama

Gerçek worker'larla, stub değil:

| Koşu | Sonuç |
|---|---|
| `doctor` — 9 worker'a canlı ping (2026-09-03) | 7 cursor worker'ı ÇALIŞIR (6-9s), 1 codex worker'ı KIRIK (404) |
| `doctor --worker gemini-agy` (2026-09-06) | ÇALIŞIR, 6s, yanıt `PONG` |
| `doctor --worker gemini` (2026-09-06) | KIRIK — Cursor kotası tükendi |
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

Bu yüzden OrchestraG uygulayan ile inceleyenin **farklı model ailesinden**
olmasını şart koşuyor. Aynı aileyle incelettiğinde bu bulgular çıkmayabilir.
Orchestra'da herkes Anthropic ailesinden olduğu için bu yapılamaz: orada en azından
farklı model istenir (`claude-sonnet` uygular, `claude-opus` inceler). Güvenlik ya
da para gibi kritik işlerde ise farklı aileden doğrulama için OrchestraG önerilir.

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
- Yalnızca yerel CLI'lar kullanılır (`agent`, `codex`, `agy`); her biri kendi
  girişini taşır. Test 16 bunu denetler.
