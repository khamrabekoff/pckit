# Продолжение работы над Hone на другом ПК

Состояние на 2026-11-05. Основная часть сделана, осталась проверка на живой системе и выбор настроек.

## Что уже сделано
- Разбор Hone: `docs/hone-analysis.md` (функции, каталог твиков, сеть, риски).
- Инструмент `tools/pckit-diff.ps1`: снимок настроек Windows и сравнение «до/после». Только чтение.
- Тест `tests/Diff.Tests.ps1`. Релиз **v2.4.0** опубликован.
- Новых настроек в `data/actions.json` пока нет: настоящие изменения Hone станут известны после снимков.

## Что осталось
1. **Шаг 2.** На ПК с Hone сделать снимки «до» и «после» и сравнить.
2. **Шаг 3.** По списку изменений составить таблицу: название, что меняет, эффект, риск, куда (обычная / expert / миф / не брать). Дождаться «да» от владельца, затем добавить в `data/actions.json` (steps, verify, честный effect) и тесты в `tests/`.
3. Идеи для кнопок на главной (только названия, без оформления Hone).
4. В конце: поднять `PckitVersion` в `engine/Common.ps1`, обновить `PCKIT.md`, прогнать `build.ps1` и все `tests/*.Tests.ps1`, выпустить релиз.

## Правила проекта (кратко)
- Берём только идеи Hone. Код, тексты, иконки не копируем.
- Безопасно для FACEIT/VAC: без драйверов, инжекта, правок памяти, отключения Defender/UAC/SmartScreen/VBS/обновлений безопасности.
- Каждая настройка откатывается через журнал (`engine/Journal.ps1`). Плацебо — это `myth: true`, рискованное и слабое — `expert: true`.
- `*.ps1` — UTF-8 с BOM, `pckit-ui.ps1` — CRLF.
- Не менять систему без подтверждения; коммиты в отдельную ветку.

## Как провести шаг 2 на другом ПК
Нужна установленная программа Hone и PowerShell **от администратора**. Желательно сначала создать точку восстановления Windows.

```bash
git clone https://github.com/khamrabekoff/pckit.git
```

```bash
cd pckit
```

Снимок «до» (до включения чего-либо в Hone):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tools\pckit-diff.ps1 -Snapshot snapshots\before.json
```

Затем в Hone включите несколько настроек (запишите, какие именно), при необходимости перезагрузитесь. Снимок «после»:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tools\pckit-diff.ps1 -Snapshot snapshots\after.json
```

Сравнение:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tools\pckit-diff.ps1 -Before snapshots\before.json -After snapshots\after.json -Report snapshots\diff.md
```

Совет: для оценки «шума» сделайте два снимка подряд без изменений и сравните их.
Папка `snapshots/` в git не попадает (в ней данные конкретного ПК).

## Что сказать Claude на другом ПК
> Продолжаем работу над pckit (репозиторий khamrabekoff/pckit). Прочитай `docs/hone-next-steps.md` и `docs/hone-analysis.md`. Снимки Hone лежат в `snapshots/` (before.json, after.json, diff.md): сравни, выполни шаг 3 (таблица предложений) и жди моего «да». Говори по-русски, объясняй просто.