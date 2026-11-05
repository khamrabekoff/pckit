# Hone: что реально меняют твики (шаг 2–3)

Дата: 2026-11-05. Hone 2.1 Premium. Метод: снимок `tools/pckit-diff.ps1` до и после **каждого** твика (`snapshots/s1..s8`, `d1..d8`).
Включено 8 твиков из блока Recommended. BIOS, Defender, UAC, SmartScreen, VBS, Mitigations не трогались. Перезагрузки ещё не было.

## Что делает каждый твик

| # | Твик Hone | Что меняет на самом деле |
|---|---|---|
| 1 | Optimize NVIDIA Performance | Ключи драйвера в `Class\{4d36e968…}\0000`: PowerMizer на максимум (`PowerMizerEnable/Level/HardLevel=1`, `PerfLevelSrc=0x2222`, `DisableDynamicPstate=1`, `EnableCoreSlowdown/NVClkSlowdown=0`); **отключение HDCP** (`RmDisableHdcp22=1`, `RMHdcpKeyglobZero=1`); **отключение preemption** (`DisablePreemption=1`, `DisableCudaContextPreemption=1`); `DisplayPowerSaving=0`; выкл. Edge Enhance / Noise Reduce / Super Resolution; `PlatformSupportMiracast=0`; профиль DRS (nvdrsdb). |
| 2 | Optimize MSI | Ставит службу **HoneSvc** (автозапуск). Сами `MSISupported=1` появились позже (шаг 6) — для GPU и двух устройств AMD. |
| 3 | Optimize Network | QoS DSCP=46 для **≈490 игр** (в т.ч. `cs2.exe`); `psched NonBestEffortLimit=0`; на интерфейсах `TCPNoDelay=1`, `TcpAckFrequency=2`, `TcpInitialRTT=1000`; у адаптеров выкл. EEE / Green Ethernet / энергосбережение / IPsec- и TCP-offload, `MIMOPowerSaveMode=3`; AFD-буферы; DNS: `NegativeCacheTime=0`, `EnableAutoDoh=2`; TCP-глобальные (`Tcp1323Opts=3`, `SackOpts=1`, `TcpTimedWaitDelay=32`, `TcpMaxConnectRetransmissions=2`); **отключены NetBT и lmhosts**; netsh tcp global. |
| 4 | Optimize FPS & Input Lag | Набор ключей ядра в `Session Manager\kernel` (`GlobalTimerResolutionRequests=1`, `SerializeTimerExpiration=1`, `ThreadDpcEnable=1` и ещё 8 недокументированных); csrss: `CpuPriorityClass=4` (High), `IoPriority=3`; `RawMouseThrottle*`; таймауты рабочего стола (`HungAppTimeout=1000`, `WaitToKillAppTimeout=1500`, `ForegroundLockTimeout=0`); Game Mode вкл; Edge prelaunch выкл; `LetAppsRunInBackground=2`; GPU `AllowDeepCStates=0`; задача `LaunchSetTimerResolution`. **Вернул к стандарту** `Games Priority=2 / Medium` и `NetworkThrottlingIndex=10` — то есть отменил то, что раньше поставил pckit. |
| 5 | Optimize Storage & Memory | NTFS: `NtfsDisableLastAccessUpdate=1`, `NtfsDisable8dot3NameCreation=1`, `NtfsMemoryUsage=2`, `NtfsMftZoneReservation=2`; память: `DisablePagingExecutive=1`, `DisablePageCombining=1`, `SystemPages=-1`; `RunStartupScriptSync=0`. |
| 6 | Optimize Device Affinities | Для GPU, сетевых карт и USB: `Affinity Policy` `DevicePolicy=4` + `AssignmentSetOverride` (жёстко на конкретные ядра), `DevicePriority=3`; `MSISupported=1`; bcdedit `disabledynamictick yes`. |
| 7 | Reduce Windows Background Activity | Выкл. службы WerSvc, wercplsupport, **PcaSvc**; политики AppCompat (`DisableEngine`, `DisablePCA`, `SbEnable=0`); WER и отчёты драйверов выкл; WCN; 20 задач планировщика (WinSAT, Maps, Speech, SpacePort, Work Folders, CacheTask…). |
| 8 | Enhance NVIDIA Privacy | Выкл. телеметрии/логирования драйвера (`RMNvLog`, `LogEnableMasks`, `EnableGpuFirmwareLogs`…=0), `OptInOrOutPreference=0`, служба **FvSvc** (FrameView SDK) → Disabled. |

## Предложения для pckit

| Предложение | Эффект | Риск | Куда |
|---|---|---|---|
| A. Сеть: выкл. EEE / Green Ethernet / энергосбережение адаптера | стабильнее пинг на части сетевых карт | низкий, откат через реестр адаптера | **обычная** |
| B. QoS DSCP=46 для cs2.exe (у нас уже есть для CS2) — без списка из 490 игр | на домашнем роутере обычно ничего | нет | оставить как есть |
| C. NTFS: `NtfsDisableLastAccessUpdate=1`, `8dot3=1` | меньше лишних записей на диск | низкий (8dot3 ломает очень старые программы) | **обычная** (last access), **expert** (8dot3) |
| D. Приватность: WER + отчёты драйверов + PcaSvc выкл | меньше фоновой активности | низкий; PcaSvc иногда нужен старым программам | **обычная** (WER), **expert** (PcaSvc) |
| E. Задачи планировщика (WinSAT, Maps, Speech, Work Folders, CacheTask) | чуть меньше фоновых запусков | низкий | **обычная** |
| F. NVIDIA: телеметрия/логи драйвера выкл, FvSvc выкл | приватность, мелочь для FPS | низкий | **обычная** |
| G. NVIDIA: PowerMizer на максимум, `DisableDynamicPstate` | GPU всегда на высоких частотах: +жар, +шум, +потребление в простое | средний | **expert** |
| H. MSI-режим для GPU | меньше задержка прерываний на части систем | средний (бывает чёрный экран на старых картах) | **expert** |
| I. Таймауты рабочего стола, `RawMouseThrottle` | ощутимо не влияет | нет | **миф** |
| J. Ядро: недокументированные `Session Manager\kernel`, csrss High, `SystemPages`, `DisablePagingExecutive`, `DisablePageCombining` | не доказано; на 64-бит и 16+ ГБ ОЗУ — плацебо | средний (недокументировано) | **миф / не брать** |
| K. Отключить HDCP, отключить preemption GPU | HDCP: перестают работать Netflix/Blu-ray; preemption: риск зависаний/TDR | высокий | **не брать** |
| L. Affinity устройств на фиксированные ядра, `disabledynamictick` | зависит от ЦП; часто хуже | высокий, зависит от железа | **не брать** |
| M. Отключить NetBT/lmhosts | ломает сетевые папки и принтеры в локалке | средний | **не брать** |
| N. Своя служба в автозапуске (HoneSvc) | — | — | **не брать** |

## Важно
- Hone в шаге 4 **вернул** `Games Priority`/`Scheduling Category` и `NetworkThrottlingIndex` к стандарту Windows. Значит, сам Hone считает наши значения (6/High и -1) бесполезными. Стоит проверить и, возможно, пометить их в pckit как `myth`.
- После решения по таблице откатить твики в Hone (Deactivate) или точкой восстановления «pckit before Hone».

## Полный проход по каталогу (все разделы)

Скрипт через agent-desktop включал твики Recommended, Free, Intermediate, Expert и Advanced по одному (41 активный в Hone), снимки в `snapshots/sweep/`, общий итог `snapshots/diff-all.md` (≈6300 изменений, из них ≈5500 — QoS-политики для 490 игр). Пропущены: Defender, SmartScreen, UAC, VBS/Hyper-V, Mitigations, VPN, обновления драйверов, установка Process Explorer и стороннего regedit.

Что ещё нашлось:
- **Optimize Windows Explorer** заодно ставит `PromptOnSecureDesktop=0` (ослабляет UAC) и `LongPathsEnabled=0`.
- **Disable Browser Updates** выключает службы обновления Chrome и Edge.
- **Reduce Ads & Tracking** пишет ~100 переменных среды «без телеметрии», в т.ч. `CI=1`.
- Блокировка Edge: `Image File Execution Options\msedge.exe` → `Debugger` = программа Hone.
- **Disable Windows Automatic Updates**: `NoAutoUpdate=1` (скрипт не распознал название — включился по ошибке, вернуть).
- **Maximum Performance Power Mode**: своя схема «Hone Ultimate Power Plan V5», `stornvme IdlePowerMode=0`, задача `DisablePowerSaving`.
- **Disable Fullscreen Optimization**: `GameConfigStore GameDVR_FSEBehavior*=2` и `__COMPAT_LAYER=~ DISABLEDXMAXIMIZEDWINDOWEDMODE` для всей системы.
- Драйвер **UCPD** выключен (Advanced), Prefetch/Superfetch выключены, SMB-параметры Lanman, `PowerWatchdog*=0`, `GraphicsDrivers\scheduler EnablePreemption=0`.
- Пять Free-твиков (контекстное меню, факс, суффикс ярлыка, логотип загрузки, Live Tiles) не изменили ничего из отслеживаемого.

## Что вошло в pckit 2.5.0
Обычные: `nic.eee.off`, `wer.full.off`, `tasks.background.off`, `nv.telemetry.off`, `ntfs.lastaccess.off`, `browsers.background.off`, `edge.sidebar.off`, `gamedvr.policy.off`, `explorer.snappy`.
Экспертные: `nic.lso.off`, `nv.pstate.max`, `gpu.msi.on`, `ntfs.8dot3.off`, `pca.off`, `svc.extra.off`.
Мифы (только объяснение): `myth.kernel.tweaks`, `myth.qos.allgames`, `myth.affinity`, `myth.danger.optimizers`.
## QuickCPU 6.8 и Process Lasso 19 (снимки `snapshots/qc/`)

- **QuickCPU** при установке ставит драйвер ядра `hwdlink.sys` (служба `cbhardwarelink2`). Всё остальное — интерфейс к настройкам схемы питания: парковка ядер, масштабирование частоты, Turbo, «Performance», выбор схемы. Частоты выше заводских не поднимает. В pckit: карточка-миф `myth.quickcpu.driver`, полезное уже даёт `power.plan`.
- **Process Lasso** ставит службу ProcessGovernor, две задачи, схему «Bitsum Highest Performance» (отличие от «Высокой» — 100% ядер без парковки, быстрее рост частоты, USB-энергосбережение). Остальное работает, только пока программа запущена: ProBalance, Gaming Mode (смена схемы при запуске игры), SmartTrim, правила приоритета/ядер/CPU Sets, foreground boost. В pckit: `cs2.priority.high` (IFEO PerfOptions, High) и `foreground.boost` (Win32PrioritySeparation=0x26), обе экспертные. Gaming Mode — кандидат на будущий «Игровой режим» pckit.
