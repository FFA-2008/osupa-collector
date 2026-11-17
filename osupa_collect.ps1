# osu!PA replay collector v1.4
#
# What this does, step by step (all of it is below, nothing is hidden):
#   1. Asks whether you play lazer, stable or both, and finds those osu! folders.
#      Then asks 6 short questions about your setup, including your screen resolution and
#      refresh rate (Enter skips any of them). These go into data.txt.
#   2. Finds your osu!standard replays in them.
#   3. Finds the .osu map file each replay was played on. Every replay stores the MD5
#      fingerprint of its map, so ONLY maps you have a replay on are taken.
#   4. Copies those replays and .osu files into zip files (at most about 2 GB each)
#      in a new folder called "osupa_upload_<date>" next to this script. The zips are named
#      "..._part1of2.zip", "..._part2of2.zip" so FFA2008 can see if one is missing.
#   5. Opens that folder and the upload page (a Google Form) in your browser, with your
#      osu! name already filled in. Nothing is uploaded unless you do it yourself.
#
# It only READS your osu! folders. It never changes, moves or deletes anything in them.
# It does not take audio, backgrounds, skins, settings, collections, account data or passwords.
# Replays contain your osu! username and play dates, like any replay you would share.
# data.txt holds only your answers to the 6 questions.
# Before anything is read, it shows the short version of DATA USE.txt and asks you to agree.
#
# Where things are:
#   lazer keeps ALL its files (audio, images, maps, replays) in one "files" folder with
#   random-looking names and no extensions, so the only way to tell which ones are replays
#   is to peek at the first few bytes of each file. The small C# block below does that
#   quickly on 4 threads (PowerShell alone was too slow).
#   stable keeps replays in Data\r and Replays, and maps in Songs. Its osu!.db lists each
#   map's fingerprint and file name, so only the right .osu files in Songs are opened.

param([string]$StablePath = "")

$ErrorActionPreference = "Stop"
$Version = "1.4"
# The upload page (Google Form). PLAYERNAME in it is replaced by your osu! name. Empty = no page.
$UploadForm = 'https://docs.google.com/forms/d/e/1FAIpQLSdU7paxKc_2gHt0Nfzv9ODscI2shLW522_G8yPj8fWj23Pv1Q/viewform?usp=pp_url&entry.967959517=PLAYERNAME'
$PartLimit = 2GB          # max bytes of files per zip part
$PartMaxEntries = 30000   # max files per zip part (keeps every part a plain, simple zip)

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class OsupaReplay
{
    public string Path;
    public int Mode;        // 0 = osu!standard
    public string Map;      // MD5 of the map the replay was played on
    public string Player;
}

public static class OsupaScan
{
    public static int Unreadable = 0;
    const int Threads = 4;

    // first bytes of a file, opened read-only without locking it (works while osu! is running)
    public static byte[] Head(string path, int count)
    {
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 128))
        {
            byte[] buf = new byte[count];
            int n = 0;
            while (n < count)
            {
                int r = fs.Read(buf, n, count - n);
                if (r <= 0) break;
                n += r;
            }
            if (n < count) Array.Resize(ref buf, n);
            return buf;
        }
    }

    public static byte[] ReadAll(string path)
    {
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            int len = (int)fs.Length;
            byte[] buf = new byte[len];
            int n = 0;
            while (n < len)
            {
                int r = fs.Read(buf, n, len - n);
                if (r <= 0) break;
                n += r;
            }
            if (n < len) Array.Resize(ref buf, n);
            return buf;
        }
    }

    public static string Hex(byte[] hash)
    {
        StringBuilder sb = new StringBuilder(hash.Length * 2);
        foreach (byte b in hash) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    public static string Md5(byte[] data)
    {
        using (MD5 md5 = MD5.Create()) return Hex(md5.ComputeHash(data));
    }

    public static string Md5File(string path)
    {
        using (MD5 md5 = MD5.Create())
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            return Hex(md5.ComputeHash(fs));
    }

    static bool IsHex(byte c) { return (c >= 48 && c <= 57) || (c >= 97 && c <= 102); }

    // osu! replay (.osr) header: game mode (1 byte), game version (4 bytes), then the map's MD5
    // as a string (0x0b, length 32, 32 hex characters), then the player name. null = not a replay.
    public static OsupaReplay ParseReplay(string path, byte[] h)
    {
        if (h.Length < 41) return null;
        if (h[0] > 3 || h[5] != 0x0b || h[6] != 0x20) return null;
        for (int i = 7; i < 39; i++) if (!IsHex(h[i])) return null;
        int ver = BitConverter.ToInt32(h, 1);
        if (ver < 20000000 || ver >= 40000000) return null;
        OsupaReplay r = new OsupaReplay();
        r.Path = path;
        r.Mode = h[0];
        r.Map = Encoding.ASCII.GetString(h, 7, 32);
        r.Player = "";
        if (h[39] == 0x0b && h[40] < 0x80 && 41 + h[40] <= h.Length) r.Player = Encoding.UTF8.GetString(h, 41, h[40]);
        return r;
    }

    // Walks a whole replay file: all its parts must add up exactly to the file size.
    // Broken (cut off) replays are skipped so every packed replay is complete.
    // Also uses the same size limits as osu!PA's intake check, so a replay that would get the
    // whole zip rejected there is left out here instead.
    public static bool StructureOk(byte[] b)
    {
        try
        {
            if (b.Length > 32 * 1024 * 1024) return false;
            int p = 0;
            p += 1;
            int ver = BitConverter.ToInt32(b, p); p += 4;
            int[] limit = { 32, 64, 32 };            // map MD5, player name, replay MD5
            for (int k = 0; k < 3; k++)
            {
                int start;
                int len = TextField(b, ref p, out start);
                if (len > limit[k]) return false;
                if (k == 2 && len > 0)
                {
                    if (len != 32) return false;
                    for (int i = start; i < start + 32; i++) if (!IsHex(b[i])) return false;
                }
            }
            p += 2 * 6 + 4 + 2 + 1;
            int mods = BitConverter.ToInt32(b, p); p += 4;
            int lifeStart;
            if (TextField(b, ref p, out lifeStart) > 65536) return false;   // life bar
            p += 8;
            int n = BitConverter.ToInt32(b, p); p += 4;
            if (n < 0 || p + n > b.Length) return false;
            p += n;
            bool tp = (mods & (1 << 23)) != 0;
            int rest = b.Length - p;
            if (ver >= 30000000)
            {
                p += 8;
                if (tp) p += 8;
                if (p > b.Length) return false;
                if (p < b.Length)
                {
                    if (p + 4 > b.Length) return false;
                    int m = BitConverter.ToInt32(b, p); p += 4;
                    if (m < 0 || m > 65536 || p + m != b.Length) return false;
                    p += m;
                }
                return p == b.Length;
            }
            return rest == 0 || rest == 4 || rest == 8 || (tp && rest == 16);
        }
        catch (Exception) { return false; }
    }

    // one text field of a replay: returns its length (0 = empty), moves p past it
    static int TextField(byte[] b, ref int p, out int start)
    {
        start = p;
        if (b[p] == 0) { p++; return 0; }
        if (b[p] != 0x0b) throw new FormatException();
        p++;
        int n = 0, shift = 0;
        while (true)
        {
            byte c = b[p++];
            n |= (c & 0x7f) << shift;
            if ((c & 0x80) == 0) break;
            shift += 7;
            if (shift > 28) throw new FormatException();
        }
        if (n < 0 || p + n > b.Length) throw new FormatException();
        start = p;
        p += n;
        return n;
    }

    // a map must be plain text (no binary bytes) starting with "osu file format", at most 16 MB:
    // the same rule as osu!PA's intake check
    public static bool MapOk(byte[] b)
    {
        if (b.Length > 16 * 1024 * 1024 || !IsOsu(b)) return false;
        foreach (byte c in b)
        {
            if (c == 127) return false;
            if (c < 32 && c != 9 && c != 10 && c != 13) return false;
        }
        return true;
    }

    static int SkipString(byte[] b, int p)
    {
        if (b[p] == 0) return p + 1;
        if (b[p] != 0x0b) throw new FormatException();
        p++;
        int n = 0, shift = 0;
        while (true)
        {
            byte c = b[p++];
            n |= (c & 0x7f) << shift;
            if ((c & 0x80) == 0) break;
            shift += 7;
            if (shift > 28) throw new FormatException();
        }
        if (n < 0 || p + n > b.Length) throw new FormatException();
        return p + n;
    }

    // .osu map files start with "osu file format" (sometimes after a BOM or blank lines)
    public static bool IsOsu(byte[] h)
    {
        int i = 0;
        if (h.Length >= 3 && h[0] == 0xef && h[1] == 0xbb && h[2] == 0xbf) i = 3;
        while (i < h.Length && (h[i] == 32 || h[i] == 9 || h[i] == 10 || h[i] == 13)) i++;
        if (h.Length - i < 15) return false;
        return Encoding.ASCII.GetString(h, i, 15) == "osu file format";
    }

    // every file under root matching pattern; folders that can't be opened and folder links are skipped
    public static List<string> Files(string root, string pattern)
    {
        List<string> list = new List<string>();
        Stack<string> stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            string dir = stack.Pop();
            try
            {
                foreach (string f in Directory.EnumerateFiles(dir, pattern)) list.Add(f);
                foreach (string d in Directory.EnumerateDirectories(dir))
                    if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) == 0) stack.Push(d);
            }
            catch (Exception) { }
        }
        return list;
    }

    // Peeks at the first 96 bytes of each file. Replays are returned; .osu map files are added
    // to osuOut (skipped if osuOut is null). Uses 4 threads and prints progress.
    public static List<OsupaReplay> Scan(List<string> paths, List<string> osuOut)
    {
        ConcurrentBag<OsupaReplay> reps = new ConcurrentBag<OsupaReplay>();
        ConcurrentBag<string> osu = new ConcurrentBag<string>();
        int done = 0;
        int total = paths.Count;
        bool wantOsu = osuOut != null;
        ParallelOptions po = new ParallelOptions();
        po.MaxDegreeOfParallelism = Threads;
        Parallel.ForEach(paths, po, delegate(string p)
        {
            try
            {
                byte[] h = Head(p, 96);
                OsupaReplay r = ParseReplay(p, h);
                if (r != null) reps.Add(r);
                else if (wantOsu && IsOsu(h)) osu.Add(p);
            }
            catch (Exception) { Interlocked.Increment(ref Unreadable); }
            int n = Interlocked.Increment(ref done);
            if (n % 25000 == 0) Console.WriteLine("  " + n + " / " + total);
        });
        if (wantOsu) osuOut.AddRange(osu);
        return new List<OsupaReplay>(reps);
    }

    // MD5 of each .osu file; returns MD5 -> path for the wanted ones. Stops once all are found.
    public static Dictionary<string, string> FindMaps(List<string> files, string[] needed)
    {
        Dictionary<string, bool> want = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (string m in needed) want[m] = true;
        Dictionary<string, string> found = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        object gate = new object();
        int done = 0;
        int total = files.Count;
        ParallelOptions po = new ParallelOptions();
        po.MaxDegreeOfParallelism = Threads;
        Parallel.ForEach(files, po, delegate(string p, ParallelLoopState state)
        {
            lock (gate) { if (found.Count >= want.Count) { state.Stop(); return; } }
            try
            {
                string m = Md5File(p);
                if (want.ContainsKey(m)) { lock (gate) { if (!found.ContainsKey(m)) found[m] = p; } }
            }
            catch (Exception) { Interlocked.Increment(ref Unreadable); }
            int n = Interlocked.Increment(ref done);
            if (n % 25000 == 0) Console.WriteLine("  " + n + " / " + total);
        });
        return found;
    }

    // osu! stable's osu!.db lists every map's MD5 followed by its .osu file name.
    // Returns the .osu file names of the wanted MD5s, so only those files need opening.
    public static Dictionary<string, bool> StableNames(string dbPath, string[] needed)
    {
        Dictionary<string, bool> want = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (string m in needed) want[m] = true;
        Dictionary<string, bool> names = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        byte[] db = ReadAll(dbPath);
        for (int i = 0; i + 36 < db.Length; i++)
        {
            if (db[i] != 0x0b || db[i + 1] != 0x20) continue;
            bool hex = true;
            for (int j = i + 2; j < i + 34; j++) if (!IsHex(db[j])) { hex = false; break; }
            if (!hex) continue;
            if (!want.ContainsKey(Encoding.ASCII.GetString(db, i + 2, 32))) continue;
            int k = i + 34;
            if (db[k] != 0x0b) continue;
            k++;
            int len = 0, shift = 0;
            while (k < db.Length && shift <= 28)
            {
                byte b = db[k++];
                len |= (b & 0x7f) << shift;
                if ((b & 0x80) == 0) break;
                shift += 7;
            }
            if (len <= 0 || k + len > db.Length) continue;
            names[Encoding.UTF8.GetString(db, k, len)] = true;
        }
        return names;
    }

    // keeps only the files whose file name is in names
    public static List<string> ByName(List<string> files, Dictionary<string, bool> names)
    {
        List<string> keep = new List<string>();
        foreach (string f in files) if (names.ContainsKey(System.IO.Path.GetFileName(f))) keep.Add(f);
        return keep;
    }
}
'@

# ---------- helpers ----------

function Find-Lazer {
    $base = Join-Path $env:APPDATA "osu"
    $ini = Join-Path $base "storage.ini"
    if (Test-Path -LiteralPath $ini) {
        foreach ($line in Get-Content -LiteralPath $ini) {
            if ($line -match '^\s*FullPath\s*=\s*(.+?)\s*$') { $base = $Matches[1] }
        }
    }
    return (Test-LazerFiles $base)
}

function Test-LazerFiles([string]$dir) {
    # lazer's data folder has a "files" folder inside; returns that folder or $null
    if (-not $dir) { return $null }
    try {
        $files = Join-Path $dir "files"
        if (Test-Path -LiteralPath $files) { return $files }
        if ((Split-Path -Leaf $dir) -eq "files" -and (Test-Path -LiteralPath $dir)) { return $dir }
    } catch { }
    return $null
}

function Test-Stable([string]$dir) {
    # a stable install has osu!.db next to osu!.exe (lazer's install folder does not)
    if (-not $dir) { return $false }
    try { return (Test-Path -LiteralPath (Join-Path $dir "osu!.db")) } catch { return $false }
}

function Find-Stable {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($StablePath) { $cands.Add($StablePath.Trim('"', ' ')) }
    $cands.Add((Join-Path $env:LOCALAPPDATA "osu!"))
    $keys = @(
        "Registry::HKEY_CLASSES_ROOT\osustable.File.osz\shell\open\command",
        "Registry::HKEY_CLASSES_ROOT\osu\shell\open\command",
        "Registry::HKEY_CURRENT_USER\Software\Classes\osu\shell\open\command"
    )
    foreach ($key in $keys) {
        try {
            $cmd = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
            if ($cmd -match '"?([^"]+\.exe)"?') { $cands.Add([System.IO.Path]::GetDirectoryName($Matches[1])) }
        } catch { }
    }
    foreach ($c in $cands) { if (Test-Stable $c) { return $c } }
    return $null
}

function Get-StableSongs([string]$stable) {
    $songs = Join-Path $stable "Songs"
    foreach ($cfg in Get-ChildItem -LiteralPath $stable -Filter "osu!.*.cfg" -File -ErrorAction SilentlyContinue) {
        foreach ($line in Get-Content -LiteralPath $cfg.FullName -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*BeatmapDirectory\s*=\s*(.+?)\s*$') {
                $d = $Matches[1]
                if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path $stable $d }
                if (Test-Path -LiteralPath $d) { $songs = $d }
            }
        }
    }
    return $songs
}

function Add-ToZip([string]$entryName, [byte[]]$bytes, $level, [datetime]$time) {
    if ($null -eq $script:zip -or ($script:partBytes + $bytes.Length) -gt $PartLimit -or $script:partEntries -ge $PartMaxEntries) {
        if ($null -ne $script:zip) { $script:zip.Dispose() }
        $script:part++
        $p = Join-Path $script:outDir ("osupa_" + $script:tag + "_" + $script:stamp + "_part" + $script:part + ".zip")
        $script:zip = [System.IO.Compression.ZipFile]::Open($p, [System.IO.Compression.ZipArchiveMode]::Create)
        $script:partBytes = 0
        $script:partEntries = 0
        $script:parts.Add($p)
        Write-Host ("  writing " + (Split-Path -Leaf $p))
    }
    $e = $script:zip.CreateEntry($entryName, $level)
    try { $e.LastWriteTime = [DateTimeOffset]$time } catch { }
    $w = $e.Open()
    try { $w.Write($bytes, 0, $bytes.Length) } finally { $w.Close() }
    $script:partBytes += $bytes.Length
    $script:partEntries++
}

# ---------- 1. which osu! ----------

Write-Host "osu!PA replay collector v$Version"
Write-Host "It only reads your osu! folders. Nothing in them is changed."
Write-Host ""
Write-Host "Before you start, please read DATA USE.txt (next to this script). Short version:"
Write-Host "  - I collect your osu!standard replays, the maps they were played on, and your answers."
Write-Host "  - They train the osu!PA engine. Never sold, shared, published or sent to an AI."
Write-Host "  - You upload them through a Google Form; I move them off Google Drive to my PC right away."
Write-Host "  - Kept on my own drives while the engine is developed. Ask me any time (ffa2008 on Discord)"
Write-Host "    and they're deleted right away; the next engine version is trained without them."
Write-Host "    - FFA2008"
$agree = ([string](Read-Host "Type y and press Enter to agree (anything else stops here)")).Trim()
if ($agree -notmatch '^[yY]') {
    Write-Host "Stopped. Nothing was collected."
    exit 1
}
$agreedAt = Get-Date -Format "yyyy-MM-dd HH:mm"
Write-Host ""
Write-Host "Which osu! do you play?"
Write-Host "  1 = lazer"
Write-Host "  2 = stable"
Write-Host "  3 = both"
$choice = ""
while (@("1", "2", "3") -notcontains $choice) { $choice = ([string](Read-Host "Type 1, 2 or 3 and press Enter")).Trim() }
$useLazer = ($choice -eq "1" -or $choice -eq "3")
$useStable = ($choice -eq "2" -or $choice -eq "3")
Write-Host ""

$lazer = $null
$stable = $null
if ($useLazer) {
    $lazer = Find-Lazer
    if (-not $lazer) {
        Write-Host "lazer: not found automatically."
        $ans = ([string](Read-Host "Paste your lazer data folder (the one with a 'files' folder inside), or press Enter to skip")).Trim('"', ' ')
        $lazer = Test-LazerFiles $ans
        if ($ans -and -not $lazer) { Write-Host "No 'files' folder there, skipping lazer." }
    }
    if ($lazer) { Write-Host "lazer found:  $lazer" }
}
if ($useStable) {
    $stable = Find-Stable
    if (-not $stable) {
        Write-Host "stable: not found automatically."
        $ans = ([string](Read-Host "Paste your stable folder (the one with osu!.exe), or press Enter to skip")).Trim('"', ' ')
        if ($ans) {
            if (Test-Stable $ans) { $stable = $ans } else { Write-Host "No osu!.db in that folder, skipping stable." }
        }
    }
    if ($stable) { Write-Host "stable found: $stable" }
}
if (-not $lazer -and -not $stable) {
    Write-Host ""
    Write-Host "No osu! folder found, nothing to collect."
    exit 1
}

# ---------- 1b. a few questions (things replays can't show) ----------

Write-Host ""
Write-Host "6 quick questions about your setup (press Enter to skip any of them):"
$qDevice = ([string](Read-Host "1. Do you play with mouse or tablet?")).Trim()
$qSens = ([string](Read-Host "2. Your tablet area or mouse sensitivity?")).Trim()
$qChange = ([string](Read-Host "3. Did you change mouse, tablet or monitor at some point? Roughly when?")).Trim()
$qOther = ([string](Read-Host "4. Anything else (injury, long break, ...)?")).Trim()
$qRes = ([string](Read-Host "5. Your screen resolution (for example 1920x1080)?")).Trim()
$qHz = ([string](Read-Host "6. Your screen refresh rate in Hz (for example 144)?")).Trim()

Write-Host "Thanks."

$clock = [System.Diagnostics.Stopwatch]::StartNew()

# ---------- 2. find replays ----------

$replays = New-Object 'System.Collections.Generic.List[object]'
$lazerOsu = New-Object 'System.Collections.Generic.List[string]'

if ($lazer) {
    Write-Host ""
    Write-Host "Listing lazer files..."
    $all = [OsupaScan]::Files($lazer, "*")
    Write-Host ("Peeking into " + $all.Count + " lazer files to find replays and maps...")
    $found = [OsupaScan]::Scan($all, $lazerOsu)
    foreach ($x in $found) { $replays.Add($x) }
    Write-Host ("lazer: " + $found.Count + " replays, " + $lazerOsu.Count + " map files")
}

if ($stable) {
    Write-Host ""
    Write-Host "Checking stable replays (Data\r and Replays)..."
    $osr = New-Object 'System.Collections.Generic.List[string]'
    foreach ($sub in @("Data", "Replays")) {
        $dir = Join-Path $stable $sub
        if (Test-Path -LiteralPath $dir) { $osr.AddRange([OsupaScan]::Files($dir, "*.osr")) }
    }
    $found = [OsupaScan]::Scan($osr, $null)
    foreach ($x in $found) { $replays.Add($x) }
    Write-Host ("stable: " + $found.Count + " replays")
}

$stdReplays = New-Object 'System.Collections.Generic.List[string]'
$needMaps = @{}
$players = @{}
$otherModes = 0
foreach ($r in $replays) {
    if ($r.Mode -ne 0) { $otherModes++; continue }
    $stdReplays.Add($r.Path)
    $needMaps[$r.Map] = $true
    if ($r.Player) { $players[$r.Player] = 1 + [int]$players[$r.Player] }
}
if ($stdReplays.Count -eq 0) {
    Write-Host ""
    Write-Host "No osu!standard replays found, nothing to collect."
    exit 1
}

# ---------- 3. find the maps those replays were played on ----------

Write-Host ""
Write-Host ("Finding the " + $needMaps.Count + " maps your replays were played on...")
$needed = [string[]]@($needMaps.Keys)
$mapPath = @{}
if ($lazerOsu.Count -gt 0) {
    $f = [OsupaScan]::FindMaps($lazerOsu, $needed)
    foreach ($kv in $f.GetEnumerator()) { $mapPath[$kv.Key] = $kv.Value }
}
$missing = [string[]]@($needed | Where-Object { -not $mapPath.ContainsKey($_) })
if ($stable -and $missing.Count -gt 0) {
    $songs = Get-StableSongs $stable
    if (Test-Path -LiteralPath $songs) {
        Write-Host "Listing stable Songs folder..."
        $songFiles = [OsupaScan]::Files($songs, "*.osu")
        $names = $null
        try { $names = [OsupaScan]::StableNames((Join-Path $stable "osu!.db"), $missing) } catch { }
        if ($null -ne $names -and $names.Count -gt 0) { $songFiles = [OsupaScan]::ByName($songFiles, $names) }
        Write-Host ("Checking " + $songFiles.Count + " stable map files...")
        $f = [OsupaScan]::FindMaps($songFiles, $missing)
        foreach ($kv in $f.GetEnumerator()) { $mapPath[$kv.Key] = $kv.Value }
    }
}
$missingMaps = $needMaps.Count - $mapPath.Count
Write-Host ("maps found: " + $mapPath.Count + " of " + $needMaps.Count)

# ---------- 4. write the zip parts ----------

$total = 0
foreach ($p in $stdReplays) { try { $total += (New-Object System.IO.FileInfo $p).Length } catch { } }
foreach ($p in $mapPath.Values) { try { $total += (New-Object System.IO.FileInfo $p).Length } catch { } }

$top = ""
$topN = 0
foreach ($kv in $players.GetEnumerator()) { if ($kv.Value -gt $topN) { $top = $kv.Key; $topN = $kv.Value } }
$script:tag = ($top -replace '[^A-Za-z0-9_\-\[\]]', '_')
if (-not $script:tag) { $script:tag = "player" }
$script:stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$script:outDir = Join-Path $PSScriptRoot ("osupa_upload_" + $script:stamp)
[void][System.IO.Directory]::CreateDirectory($script:outDir)

$free = -1
try { $free = (New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($script:outDir))).AvailableFreeSpace } catch { }
Write-Host ""
Write-Host ("About " + [math]::Round($total / 1MB) + " MB to pack.")
if ($free -ge 0 -and $free -lt $total + 200MB) {
    $go = Read-Host ("Only " + [math]::Round($free / 1MB) + " MB free on this drive. Continue anyway? (y/n)")
    if ($go -notmatch '^[yY]') { Write-Host "Stopped. Move this folder to a drive with more space and run it again."; exit 1 }
}

$script:zip = $null
$script:part = 0
$script:partBytes = 0
$script:partEntries = 0
$script:parts = New-Object System.Collections.Generic.List[string]
$seen = @{}
$dupes = 0
$broken = 0
$packed = 0
$packedMaps = 0
$unreadable = 0
$oddMaps = 0

Write-Host "Packing replays..."
$k = 0
foreach ($p in $stdReplays) {
    $k++
    if ($k % 2000 -eq 0) { Write-Host ("  " + $k + " / " + $stdReplays.Count) }
    try {
        $b = [OsupaScan]::ReadAll($p)
        if (-not [OsupaScan]::StructureOk($b)) { $broken++; continue }   # cut-off / damaged replay
        $id = [OsupaScan]::Md5($b)
        if ($seen.ContainsKey($id)) { $dupes++; continue }   # same replay in lazer and stable: keep one
        $seen[$id] = $true
        Add-ToZip ("replays/" + $id + ".osr") $b ([System.IO.Compression.CompressionLevel]::NoCompression) ([System.IO.File]::GetLastWriteTime($p))
        $packed++
    } catch { $unreadable++ }
}
Write-Host "Packing maps..."
foreach ($kv in $mapPath.GetEnumerator()) {
    try {
        $b = [OsupaScan]::ReadAll($kv.Value)
        if (-not [OsupaScan]::MapOk($b)) { $oddMaps++; continue }   # not plain text: intake would reject the zip
        Add-ToZip ("maps/" + $kv.Key + ".osu") $b ([System.IO.Compression.CompressionLevel]::Optimal) ([System.IO.File]::GetLastWriteTime($kv.Value))
        $packedMaps++
    } catch { $unreadable++ }
}
$unreadable += [OsupaScan]::Unreadable
$minutes = [math]::Round($clock.Elapsed.TotalMinutes, 1)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("osu!PA replay collector v$Version")
$lines.Add("collected: " + (Get-Date -Format "yyyy-MM-dd HH:mm") + "   took: " + $minutes + " min")
$lines.Add("lazer: " + [bool]$lazer + "   stable: " + [bool]$stable)
$lines.Add("osu!standard replays packed: " + $packed + "   (duplicates skipped: " + $dupes + ", other game modes skipped: " + $otherModes + ", damaged skipped: " + $broken + ")")
$lines.Add("maps packed: " + $packedMaps + "   (maps not found: " + $missingMaps + ", odd maps skipped: " + $oddMaps + ")")
$lines.Add("unreadable files skipped: " + $unreadable)
$lines.Add("")
$lines.Add("players in these replays (replay count):")
foreach ($kv in ($players.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 30)) {
    $lines.Add("  " + $kv.Key + ": " + $kv.Value)
}
$summary = [string]::Join("`r`n", $lines.ToArray()) + "`r`n"

$clientText = "lazer + stable"
if ($choice -eq "1") { $clientText = "lazer" } elseif ($choice -eq "2") { $clientText = "stable" }
$data = New-Object System.Collections.Generic.List[string]
$data.Add("osu!PA collector v$Version - player data")
$data.Add("agreed to DATA USE.txt (version 2): yes, " + $agreedAt)
$data.Add("osu! name (from replays): " + $top)
$data.Add("client: " + $clientText)
$data.Add("mouse or tablet: " + $qDevice)
$data.Add("tablet area / mouse sensitivity: " + $qSens)
$data.Add("setup changes: " + $qChange)
$data.Add("anything else: " + $qOther)
$data.Add("screen resolution: " + $qRes)
$data.Add("refresh rate (Hz): " + $qHz)
$dataText = [string]::Join("`r`n", $data.ToArray()) + "`r`n"
Add-ToZip "data.txt" ([System.Text.Encoding]::UTF8.GetBytes($dataText)) ([System.IO.Compression.CompressionLevel]::Optimal) (Get-Date)
Add-ToZip "summary.txt" ([System.Text.Encoding]::UTF8.GetBytes($summary)) ([System.IO.Compression.CompressionLevel]::Optimal) (Get-Date)
$script:zip.Dispose()

# name the parts "part1of3", "part2of3", ... now that the number of parts is known
$final = New-Object System.Collections.Generic.List[string]
$nParts = $script:parts.Count
for ($i = 0; $i -lt $nParts; $i++) {
    $old = $script:parts[$i]
    $new = $old.Substring(0, $old.Length - 4) + "of" + $nParts + ".zip"
    [System.IO.File]::Move($old, $new)
    $final.Add($new)
}
# the readable copies go in a subfolder, so only the zips sit in the folder to upload
$infoDir = Join-Path $script:outDir "info (no need to upload)"
[void][System.IO.Directory]::CreateDirectory($infoDir)
[System.IO.File]::WriteAllText((Join-Path $infoDir "summary.txt"), $summary)
[System.IO.File]::WriteAllText((Join-Path $infoDir "data.txt"), $dataText)

$size = 0
foreach ($p in $final) { $size += (New-Object System.IO.FileInfo $p).Length }
Write-Host ""
Write-Host $summary
Write-Host ("DONE in " + $minutes + " min. " + $nParts + " zip file(s), " + [math]::Round($size / 1MB) + " MB in total, in:")
Write-Host ("  " + $script:outDir)
Write-Host ""
Write-Host ("UPLOAD ALL " + $nParts + " OF THESE FILES (unchanged, don't unzip or rename them):")
foreach ($p in $final) { Write-Host ("  " + (Split-Path -Leaf $p) + "   (" + [math]::Round((New-Object System.IO.FileInfo $p).Length / 1MB) + " MB)") }
try { Invoke-Item -LiteralPath $script:outDir } catch { }
if ($UploadForm) {
    $url = $UploadForm.Replace("PLAYERNAME", [System.Uri]::EscapeDataString($top))
    Write-Host ""
    Write-Host "The upload page is opening in your browser (you need to sign in with Google)."
    Write-Host "If it doesn't open, copy this link into your browser:"
    Write-Host ("  " + $url)
    try { Start-Process $url } catch { }
} else {
    Write-Host "Send these files to FFA2008."
}
Write-Host "You can delete the osupa_upload folder once the upload page says your answer was recorded."
