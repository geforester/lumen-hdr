# lumen-hdr

Свой аналог Radiance: из обычной (SDR) фотки делает HDR-файл с **gain map**, чтобы на HDR-экранах
(Mac с XDR/EDR, iPhone, Android, Chrome) светлые места светились ярче белого. Без поддержки HDR
файл выглядит ровно как исходник: база — оригинал, карта усиления лежит рядом во втором изображении.

## Как пользоваться

- открыть фото (перетащить в окно, ⌘O, «Открыть в программе → Lumen» в Finder);
- **Баланс** — откуда начинается свечение: 0 — только самые яркие места, 100 — и средние тона;
- **Сила** — насколько светлое поднимается над белым: 0…100 → 0…3 стопа (до ×8);
- **Сравнить** — держать кнопку или пробел, пока нажато, виден оригинал;
- **Экспорт** (⌘E JPEG, ⇧⌘E HEIC) — по умолчанию `имя.hdr.jpg` рядом с исходником.

Ползунки запоминаются между запусками.

## Сборка

```bash
./build.sh                                    # → /Applications/Lumen.app + ~/.local/bin/lumen
lumen convert a.jpg b.jpg -b 48 -p 75         # пачкой из терминала → a.hdr.jpg, b.hdr.jpg
lumen convert a.jpg --heic -o out.heic
```

Требует macOS 26+ (`CIImage.settingContentHeadroom`), Xcode с Metal toolchain.

## Как устроено

- `src/Lumen.ci.metal` — ядро: маска из слегка размытой яркости (смесь luma и max(R,G,B), чтобы
  насыщенные цвета на свету тоже светились), `smoothstep(порог, 1)`, усиление `2^(стопы·маска)`.
  Усиление — скаляр на пиксель, цветность не меняется → gain map монохромная.
- Экспорт — `CIContext.writeJPEG/HEIFRepresentation` с `.hdrImage`: Core Image сам считает
  отношение HDR/SDR и пишет **ISO 21496-1** gain map (проверено: `HDRToneMap`, AlternateHeadroom
  = стопы, карта в полном разрешении). Apple-овской старой карты (`HDRGainMap`) и XMP `hdrgm`
  (Google Ultra HDR) нет.
- Превью — `MTKView` с `rgba16Float` + `wantsExtendedDynamicRangeContent`, extended linear P3;
  превью считается по копии ≤2560 px, радиус размытия маски — в долях кадра, поэтому совпадает с экспортом.

## Статус

- 2026-11-25: собрано, экспорт JPEG/HEIC проверен по метаданным (`ISO GainMap: yes`, headroom
  2.25 стопа при силе 75). Окно открывается, превью рисуется.
- Не проверено на живых площадках: Instagram/Threads/Telegram, Chrome на Android. Если какая-то
  не видит HDR — первым делом добавлять XMP `hdrgm` (Ultra HDR) рядом с ISO-метаданными.
