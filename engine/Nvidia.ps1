#Requires -Version 5.1
# pckit engine | nvidia: настройки профиля драйвера NVIDIA для игры (через nvapi64.dll, без сторонних программ)
# Раскладка структур и номера функций сверены с NVIDIA Profile Inspector (github.com/Orbmu2k/nvidiaProfileInspector).
# Каждое изменение пишется в журнал (journal.nvidia) и откатывается точно: старое значение или «по умолчанию драйвера».

$script:PckitNvSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Pckit
{
    [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Unicode, Size = 4100)]
    public struct NvUnion
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4100)]
        public byte[] raw;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Unicode)]
    public struct NvSetting
    {
        public uint version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 2048)]
        public string settingName;
        public uint settingId;
        public int settingType;
        public int settingLocation;
        public uint isCurrentPredefined;
        public uint isPredefinedValid;
        public NvUnion predefinedValue;
        public NvUnion currentValue;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Unicode)]
    public struct NvApp
    {
        public uint version;
        public uint isPredefined;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 2048)]
        public string appName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 2048)]
        public string userFriendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 2048)]
        public string launcher;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 2048)]
        public string fileInFolder;
        public uint bits;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 2048)]
        public string commandLine;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Unicode)]
    public struct NvProfile
    {
        public uint version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 2048)]
        public string profileName;
        public uint gpuSupport;
        public uint isPredefined;
        public uint numOfApps;
        public uint numOfSettings;
    }

    public class NvSettingState
    {
        public int Status;
        public bool Found;
        public uint Value;
        public int Location;          // 0 = профиль игры, 1/2 = глобальный/базовый, 3 = по умолчанию
        public bool IsPredefined;     // значение задано самим драйвером (не пользователем)
        public uint PredefinedValue;
        public bool PredefinedValid;
    }

    public static class NvDrs
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr LoadLibrary(string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr h, string name);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr QueryDelegate(uint id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int VoidDelegate();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SessionOutDelegate(ref IntPtr h);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SessionDelegate(IntPtr h);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FindAppDelegate(IntPtr s, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder app, ref IntPtr p, ref NvApp a);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ProfileInfoDelegate(IntPtr s, IntPtr p, ref NvProfile info);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetSettingDelegate(IntPtr s, IntPtr p, uint id, ref NvSetting st, ref uint x);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SetSettingDelegate(IntPtr s, IntPtr p, ref NvSetting st, uint x, uint y);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int IdDelegate(IntPtr s, IntPtr p, uint id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DriverVersionDelegate(ref uint ver, [MarshalAs(UnmanagedType.LPStr)] StringBuilder branch);

        static QueryDelegate query;
        static bool ready;

        static T Get<T>(uint id, uint fallback) where T : class
        {
            IntPtr p = query(id);
            if (p == IntPtr.Zero && fallback != 0) p = query(fallback);
            if (p == IntPtr.Zero) throw new Exception(string.Format("nvapi: функция 0x{0:X8} не найдена", id));
            return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
        }

        public static uint Ver<T>(int v) { return (uint)(Marshal.SizeOf(typeof(T)) | (v << 16)); }

        // false = нет драйвера NVIDIA (нет nvapi64.dll) или он не запускается
        public static bool Init()
        {
            if (ready) return true;
            IntPtr lib = LoadLibrary(IntPtr.Size == 8 ? "nvapi64.dll" : "nvapi.dll");
            if (lib == IntPtr.Zero) return false;
            IntPtr q = GetProcAddress(lib, "nvapi_QueryInterface");
            if (q == IntPtr.Zero) return false;
            query = (QueryDelegate)Marshal.GetDelegateForFunctionPointer(q, typeof(QueryDelegate));
            int st = Get<VoidDelegate>(0x0150E828, 0)();
            ready = (st == 0);
            return ready;
        }

        public static string DriverVersion()
        {
            uint v = 0;
            var sb = new StringBuilder(64);
            int st = Get<DriverVersionDelegate>(0x2926AAAD, 0)(ref v, sb);
            if (st != 0) return null;
            return string.Format("{0}.{1:00}", v / 100, v % 100);
        }

        static IntPtr OpenSession()
        {
            IntPtr s = IntPtr.Zero;
            int st = Get<SessionOutDelegate>(0x0694D52E, 0)(ref s);
            if (st != 0) throw new Exception("nvapi: не удалось открыть сессию, код " + st);
            st = Get<SessionDelegate>(0x375DBD6B, 0)(s);
            if (st != 0) { CloseSession(s); throw new Exception("nvapi: не удалось загрузить настройки, код " + st); }
            return s;
        }

        static void CloseSession(IntPtr s) { Get<SessionDelegate>(0xDAD9CFF8, 0)(s); }

        static IntPtr FindProfile(IntPtr s, string exe, out string name)
        {
            name = null;
            IntPtr p = IntPtr.Zero;
            var app = new NvApp();
            app.version = Ver<NvApp>(4);
            int st = Get<FindAppDelegate>(0xEEE566B2, 0)(s, new StringBuilder(exe), ref p, ref app);
            if (st != 0 || p == IntPtr.Zero) return IntPtr.Zero;
            var info = new NvProfile();
            info.version = Ver<NvProfile>(1);
            if (Get<ProfileInfoDelegate>(0x61CD6FD6, 0)(s, p, ref info) == 0) name = info.profileName;
            return p;
        }

        // имя профиля драйвера, в котором лежит exe, или null
        public static string ProfileName(string exe)
        {
            IntPtr s = OpenSession();
            try { string n; FindProfile(s, exe, out n); return n; }
            finally { CloseSession(s); }
        }

        static NvSettingState Read(IntPtr s, IntPtr p, uint id)
        {
            var r = new NvSettingState();
            var st = new NvSetting();
            st.version = Ver<NvSetting>(1);
            st.predefinedValue.raw = new byte[4100];
            st.currentValue.raw = new byte[4100];
            uint x = 0;
            r.Status = Get<GetSettingDelegate>(0xEA99498D, 0x73BF8338)(s, p, id, ref st, ref x);
            if (r.Status != 0) return r;
            r.Found = true;
            r.Value = BitConverter.ToUInt32(st.currentValue.raw, 0);
            r.Location = st.settingLocation;
            r.IsPredefined = st.isCurrentPredefined != 0;
            r.PredefinedValid = st.isPredefinedValid != 0;
            r.PredefinedValue = BitConverter.ToUInt32(st.predefinedValue.raw, 0);
            return r;
        }

        public static NvSettingState GetDword(string exe, uint id)
        {
            IntPtr s = OpenSession();
            try
            {
                string n;
                IntPtr p = FindProfile(s, exe, out n);
                if (p == IntPtr.Zero) return new NvSettingState { Status = -166 };
                return Read(s, p, id);
            }
            finally { CloseSession(s); }
        }

        public static int SetDword(string exe, uint id, uint value)
        {
            IntPtr s = OpenSession();
            try
            {
                string n;
                IntPtr p = FindProfile(s, exe, out n);
                if (p == IntPtr.Zero) return -166;
                var st = new NvSetting();
                st.version = Ver<NvSetting>(1);
                st.settingId = id;
                st.settingType = 0;
                st.settingLocation = 0;
                st.predefinedValue.raw = new byte[4100];
                st.currentValue.raw = new byte[4100];
                BitConverter.GetBytes(value).CopyTo(st.currentValue.raw, 0);
                int r = Get<SetSettingDelegate>(0x8A2CF5F5, 0x577DD202)(s, p, ref st, 0, 0);
                if (r != 0) return r;
                return Get<SessionDelegate>(0xFCBC7E14, 0)(s);
            }
            finally { CloseSession(s); }
        }

        // вернуть настройку профиля к значению драйвера (или убрать, если у драйвера её нет)
        public static int RestoreDefault(string exe, uint id)
        {
            IntPtr s = OpenSession();
            try
            {
                string n;
                IntPtr p = FindProfile(s, exe, out n);
                if (p == IntPtr.Zero) return -166;
                int r = Get<IdDelegate>(0x7DD5B261, 0x53F0381E)(s, p, id);
                if (r != 0 && r != -160) return r;
                return Get<SessionDelegate>(0xFCBC7E14, 0)(s);
            }
            finally { CloseSession(s); }
        }
    }
}
'@

function Initialize-PckitNvApi {
    if (-not ('Pckit.NvDrs' -as [type])) {
        Add-Type -TypeDefinition $script:PckitNvSource -Language CSharp -ErrorAction Stop
    }
    try { return [Pckit.NvDrs]::Init() } catch { return $false }
}

function Test-PckitNvidiaPresent {
    try {
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if ([string]$g.Name -match 'NVIDIA' -or [string]$g.AdapterCompatibility -match 'NVIDIA') { return $true }
        }
    } catch { }
    return $false
}

# состояние одной настройки профиля игры: { Ok, Value, Detail, Status }
function Get-PckitNvSetting {
    param([string]$Exe, [uint32]$Id)
    if (-not (Test-PckitNvidiaPresent)) { return [pscustomobject]@{ Status = 'novendor'; Value = $null; Profile = $null } }
    if (-not (Initialize-PckitNvApi)) { return [pscustomobject]@{ Status = 'nodriver'; Value = $null; Profile = $null } }
    try {
        $profileName = [Pckit.NvDrs]::ProfileName($Exe)
        if (-not $profileName) { return [pscustomobject]@{ Status = 'noprofile'; Value = $null; Profile = $null } }
        $s = [Pckit.NvDrs]::GetDword($Exe, $Id)
        if (-not $s.Found) {
            return [pscustomobject]@{ Status = 'default'; Value = $null; Profile = $profileName; UserSet = $false }
        }
        # пользовательское значение именно в профиле игры (не то, что драйвер поставил сам)
        $userSet = ($s.Location -eq 0 -and -not $s.IsPredefined)
        return [pscustomobject]@{ Status = 'ok'; Value = [uint32]$s.Value; Profile = $profileName; UserSet = $userSet; Location = $s.Location }
    } catch {
        return [pscustomobject]@{ Status = 'error'; Value = $null; Profile = $null; Message = $_.Exception.Message }
    }
}

function Add-PckitNvTracked {
    param($Journal, [string]$Exe, [uint32]$Id, [string]$Title, $Previous)
    if (-not $Journal.Contains('nvidia')) { $Journal.nvidia = New-Object System.Collections.ArrayList }
    # одну настройку записываем один раз: при повторном применении первое «до» не теряем
    foreach ($e in @($Journal.nvidia)) {
        if ($script:PckitBatchSince -and $e -and [string]$e.at -lt $script:PckitBatchSince) { continue }
        if ($script:PckitCurrentAct -and $e -and [string]$e.act -and [string]$e.act -ne $script:PckitCurrentAct) { continue }
        if ($e -and [string]$e.exe -eq $Exe -and [uint32]$e.id -eq $Id) { return }
    }
    $restore = 'default'
    $value = $null
    if ($Previous -and $Previous.Status -eq 'ok' -and $Previous.UserSet) { $restore = 'value'; $value = [uint32]$Previous.Value }
    [void]$Journal.nvidia.Add([pscustomobject]@{
            exe     = $Exe
            id      = [uint32]$Id
            title   = $Title
            restore = $restore
            value   = $value
            profile = [string]$Previous.Profile
            at      = (Get-Date).ToString('s')
        })
}

# шаг действия: { "type": "nvidia", "exe": "cs2.exe", "id": 274197361, "value": 1, "title": "..." }
function Invoke-PckitStepNvidia {
    param($Step, $Journal, [switch]$Run)

    $exe = [string]$Step.exe
    $id = [uint32]$Step.id
    $target = [uint32]$Step.value
    $cur = Get-PckitNvSetting -Exe $exe -Id $id
    switch ($cur.Status) {
        'novendor'  { return [pscustomobject]@{ Status = 'skip'; Message = 'видеокарта не NVIDIA'; Failed = 0 } }
        'nodriver'  { return [pscustomobject]@{ Status = 'skip'; Message = 'драйвер NVIDIA не отвечает'; Failed = 0 } }
        'noprofile' { return [pscustomobject]@{ Status = 'skip'; Message = ('в драйвере нет профиля для {0} — обновите драйвер' -f $exe); Failed = 0 } }
        'error'     { return [pscustomobject]@{ Status = 'fail'; Message = $cur.Message; Failed = 1 } }
    }
    if ($cur.Status -eq 'ok' -and $cur.Value -eq $target) { return [pscustomobject]@{ Status = 'ok'; Message = 'уже так'; Failed = 0 } }
    if (-not $Run) {
        return [pscustomobject]@{ Status = 'dry'; Message = ('NVIDIA «{0}»: {1}' -f $cur.Profile, $Step.title); Failed = 0 }
    }
    try {
        $code = [Pckit.NvDrs]::SetDword($exe, $id, $target)
        if ($code -ne 0) { return [pscustomobject]@{ Status = 'fail'; Message = ('nvapi код {0}' -f $code); Failed = 1 } }
        if ($Journal) { Add-PckitNvTracked -Journal $Journal -Exe $exe -Id $id -Title ([string]$Step.title) -Previous $cur }
        return [pscustomobject]@{ Status = 'ok'; Message = ''; Failed = 0 }
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Message = $_.Exception.Message; Failed = 1 }
    }
}

# проверка: { "type": "nvidia", "exe": "cs2.exe", "id": ..., "value": ... } -> Ok / Detail / NotApplicable
function Test-PckitVerifyNvidia {
    param($Verify)
    $cur = Get-PckitNvSetting -Exe ([string]$Verify.exe) -Id ([uint32]$Verify.id)
    switch ($cur.Status) {
        'novendor'  { return [pscustomobject]@{ Ok = $false; Detail = 'не NVIDIA'; NotApplicable = $true } }
        'nodriver'  { return [pscustomobject]@{ Ok = $false; Detail = 'драйвер не отвечает'; NotApplicable = $true } }
        'noprofile' { return [pscustomobject]@{ Ok = $false; Detail = 'нет профиля игры'; NotApplicable = $true } }
        'error'     { return [pscustomobject]@{ Ok = $false; Detail = $cur.Message; NotApplicable = $false } }
        'default'   { return [pscustomobject]@{ Ok = $false; Detail = 'по умолчанию'; NotApplicable = $false } }
    }
    return [pscustomobject]@{ Ok = ([uint32]$cur.Value -eq [uint32]$Verify.value); Detail = ('сейчас: 0x{0:X}' -f $cur.Value); NotApplicable = $false }
}

# откат из журнала: newest first
function Restore-PckitNvidiaJournal {
    param($Entries, [switch]$Run)

    $result = New-Object System.Collections.ArrayList
    $list = @($Entries | Where-Object { $_ })
    [array]::Reverse($list)
    $ready = $false
    if ($Run -and $list.Count) { $ready = Initialize-PckitNvApi }
    foreach ($e in $list) {
        $title = ('NVIDIA {0}: {1}' -f $e.exe, $e.title)
        $status = 'dry'; $msg = ''
        if ($Run) {
            if (-not $ready) {
                $status = 'fail'; $msg = 'драйвер NVIDIA не отвечает'
            } else {
                try {
                    if ([string]$e.restore -eq 'value') {
                        $code = [Pckit.NvDrs]::SetDword([string]$e.exe, [uint32]$e.id, [uint32]$e.value)
                    } else {
                        $code = [Pckit.NvDrs]::RestoreDefault([string]$e.exe, [uint32]$e.id)
                    }
                    if ($code -eq 0) { $status = 'ok' }
                    elseif ($code -eq -166) { $status = 'skip'; $msg = 'профиля игры больше нет' }
                    else { $status = 'fail'; $msg = ('nvapi код {0}' -f $code) }
                } catch { $status = 'fail'; $msg = $_.Exception.Message }
            }
        }
        [void]$result.Add([pscustomobject]@{ Kind = 'видеокарта'; Title = $title; Status = $status; Message = $msg; Entry = $e })
    }
    return $result.ToArray()
}
