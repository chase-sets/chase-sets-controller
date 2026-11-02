// Nested heavy-admission execution authority for Windows (issue #7941).
//
// invoke-heavy-verifier.ps1 compiles this file in-process with Add-Type and
// runs exactly one NestedOwnerServer on a private .NET thread inside the
// exact wrapper process that owns the verify-lock.d record. A guarded process
// (or any live descendant of the guarded root) proves its right to continue
// under the wrapper's admission through a fresh named-pipe exchange:
//
//   * the client's actual process identity comes from the kernel
//     (GetNamedPipeClientProcessId), never from the payload;
//   * every process on the path from the actual client to the exact guarded
//     root, and from that root to the bound dispatch child (or its launching
//     wrapper for a closed host verifier), is opened with a
//     non-inheritable handle, its exact creation time is read with
//     GetProcessTimes, parent edges come from two Toolhelp snapshots, and every
//     handle must still be non-signaled immediately before the reply;
//   * the wrapper re-reads its own owner record, the bound dispatch ownership
//     record, and the live worktree Git identity in-process on every call;
//   * the reply is signed with a wrapper-only ECDSA P-256 key over the client's
//     fresh challenge and every identity field, so no cached, replayed, or
//     borrowed authority can be presented by a sibling.
//
// Nothing here spawns a process, writes a file, or changes the owner record.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace ChaseSets.HeavyAdmission
{
    internal static class Native
    {
        internal const uint PIPE_ACCESS_DUPLEX = 0x00000003;
        internal const uint FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
        internal const uint FILE_FLAG_OVERLAPPED = 0x40000000;
        internal const uint PIPE_TYPE_BYTE = 0x00000000;
        internal const uint PIPE_READMODE_BYTE = 0x00000000;
        internal const uint PIPE_WAIT = 0x00000000;
        internal const uint PIPE_REJECT_REMOTE_CLIENTS = 0x00000008;
        internal const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000;
        internal const uint SYNCHRONIZE = 0x00100000;
        internal const uint WAIT_OBJECT_0 = 0x00000000;
        internal const uint WAIT_TIMEOUT = 0x00000102;
        internal const uint TH32CS_SNAPPROCESS = 0x00000002;

        [StructLayout(LayoutKind.Sequential)]
        internal struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
        }

        // Canonical PROCESSENTRY32W layout (tlhelp32.h). Only its size is used.
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct PROCESSENTRY32W_LAYOUT
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }

        // Blittable twin of the layout above: the trailing szExeFile bytes are
        // reserved by Size and never read, so enumeration pins instead of
        // marshaling a 260-character string per process.
        [StructLayout(LayoutKind.Sequential, Size = 568)]
        internal struct PROCESSENTRY32W
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
        }

        internal static readonly int ProcessEntrySize = CheckedProcessEntrySize();

        private static int CheckedProcessEntrySize()
        {
            int layout = Marshal.SizeOf(typeof(PROCESSENTRY32W_LAYOUT));
            int blittable = Marshal.SizeOf(typeof(PROCESSENTRY32W));
            if (layout != blittable)
            {
                throw new PlatformNotSupportedException("PROCESSENTRY32W size mismatch: layout " + layout + " blittable " + blittable);
            }
            return blittable;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafePipeHandle CreateNamedPipeW(
            string lpName, uint dwOpenMode, uint dwPipeMode, uint nMaxInstances,
            uint nOutBufferSize, uint nInBufferSize, uint nDefaultTimeOut,
            ref SECURITY_ATTRIBUTES lpSecurityAttributes);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern SafeProcessHandle OpenProcess(
            uint dwDesiredAccess, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetProcessTimes(
            SafeProcessHandle hProcess, out long lpCreationTime, out long lpExitTime,
            out long lpKernelTime, out long lpUserTime);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(SafeHandle hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern SafeFileHandle CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool Process32FirstW(SafeFileHandle hSnapshot, ref PROCESSENTRY32W lppe);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool Process32NextW(SafeFileHandle hSnapshot, ref PROCESSENTRY32W lppe);

        [DllImport("kernel32.dll")]
        internal static extern uint GetCurrentProcessId();

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [StructLayout(LayoutKind.Sequential)]
        internal struct FILE_ATTRIBUTE_TAG_INFO { public uint Attributes; public uint ReparseTag; }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass,
            out FILE_ATTRIBUTE_TAG_INFO info, uint size);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,
            StringBuilder path, uint size, uint flags);
    }

    /// <summary>One opened live process: exact PID plus kernel creation time.</summary>
    public sealed class ProcessProbe : IDisposable
    {
        private readonly SafeProcessHandle _handle;

        private ProcessProbe(int pid, long creationTicks, SafeProcessHandle handle)
        {
            Pid = pid;
            CreationTicks = creationTicks;
            _handle = handle;
        }

        public int Pid { get; private set; }

        /// <summary>UTC ticks of the kernel creation time (100 ns resolution).</summary>
        public long CreationTicks { get; private set; }

        public string CreationUtc
        {
            get { return new DateTime(CreationTicks, DateTimeKind.Utc).ToString("o", CultureInfo.InvariantCulture); }
        }

        /// <summary>Opens a process with a non-inheritable query/synchronize handle; null when absent or unreadable.</summary>
        public static ProcessProbe Open(int pid)
        {
            if (pid <= 0) return null;
            SafeProcessHandle handle = Native.OpenProcess(
                Native.PROCESS_QUERY_LIMITED_INFORMATION | Native.SYNCHRONIZE, false, (uint)pid);
            if (handle == null || handle.IsInvalid)
            {
                if (handle != null) handle.Dispose();
                return null;
            }
            long creation, exit, kernel, user;
            if (!Native.GetProcessTimes(handle, out creation, out exit, out kernel, out user))
            {
                handle.Dispose();
                return null;
            }
            long ticks;
            try
            {
                ticks = DateTime.FromFileTimeUtc(creation).Ticks;
            }
            catch (ArgumentOutOfRangeException)
            {
                handle.Dispose();
                return null;
            }
            return new ProcessProbe(pid, ticks, handle);
        }

        /// <summary>True only while the process object is still non-signaled (not exited).</summary>
        public bool IsLive()
        {
            return Native.WaitForSingleObject(_handle, 0) == Native.WAIT_TIMEOUT;
        }

        public void Dispose()
        {
            _handle.Dispose();
        }
    }

    /// <summary>Result of one ancestry walk between two exact process identities.</summary>
    public sealed class AncestryProbe
    {
        public bool Contained { get; set; }
        public string Reason { get; set; }
        public int Hops { get; set; }
        public int[] Chain { get; set; }
    }

    public static class ProcessTree
    {
        public const int MaxHops = 128;

        public static bool TryParseUtcTicks(string identity, out long ticks)
        {
            ticks = 0;
            if (identity == null || !Regex.IsMatch(identity, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{7}Z$")) return false;
            DateTimeOffset parsed;
            if (!DateTimeOffset.TryParse(identity, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out parsed))
            {
                return false;
            }
            ticks = parsed.UtcTicks;
            return true;
        }

        /// <summary>Exact start identity of a live process in the same "o" form PowerShell publishes, or null.</summary>
        public static string StartIdentity(int pid)
        {
            using (ProcessProbe probe = ProcessProbe.Open(pid))
            {
                if (probe == null || !probe.IsLive()) return null;
                return probe.CreationUtc;
            }
        }

        public static uint CurrentProcessId()
        {
            return Native.GetCurrentProcessId();
        }

        internal sealed class Snapshot
        {
            public Dictionary<int, int> ParentOf = new Dictionary<int, int>();
            public bool Duplicate;
            public bool Unreadable;
        }

        internal static Snapshot TakeSnapshot()
        {
            Snapshot snapshot = new Snapshot();
            using (SafeFileHandle handle = Native.CreateToolhelp32Snapshot(Native.TH32CS_SNAPPROCESS, 0))
            {
                if (handle == null || handle.IsInvalid)
                {
                    snapshot.Unreadable = true;
                    return snapshot;
                }
                Native.PROCESSENTRY32W entry = new Native.PROCESSENTRY32W();
                entry.dwSize = (uint)Native.ProcessEntrySize;
                if (!Native.Process32FirstW(handle, ref entry))
                {
                    snapshot.Unreadable = true;
                    return snapshot;
                }
                do
                {
                    int pid = unchecked((int)entry.th32ProcessID);
                    int parent = unchecked((int)entry.th32ParentProcessID);
                    if (snapshot.ParentOf.ContainsKey(pid))
                    {
                        snapshot.Duplicate = true;
                    }
                    else
                    {
                        snapshot.ParentOf[pid] = parent;
                    }
                } while (Native.Process32NextW(handle, ref entry));
                if (Marshal.GetLastWin32Error() != 18) snapshot.Unreadable = true;
            }
            return snapshot;
        }

        /// <summary>
        /// Walks parent edges from an already-opened descendant up to the exact
        /// ancestor identity. Every visited process is opened (non-inheritable),
        /// must be live, and must not have been created after its child. The
        /// opened probes are appended to <paramref name="held"/> so the caller
        /// can re-check liveness immediately before replying.
        /// </summary>
        internal static AncestryProbe WalkUp(
            Snapshot snapshot, ProcessProbe descendant, int ancestorPid, long ancestorTicks,
            List<ProcessProbe> held, HashSet<int> visited, List<int> chain)
        {
            AncestryProbe result = new AncestryProbe { Contained = false, Hops = 0 };
            if (snapshot.Unreadable) { result.Reason = "process snapshot unreadable"; return result; }
            if (snapshot.Duplicate) { result.Reason = "process snapshot listed a duplicate pid"; return result; }
            ProcessProbe current = descendant;
            while (true)
            {
                if (current.Pid == ancestorPid)
                {
                    if (current.CreationTicks != ancestorTicks) { result.Reason = "ancestor pid reused"; return result; }
                    result.Contained = true;
                    result.Chain = chain.ToArray();
                    return result;
                }
                if (result.Hops >= MaxHops) { result.Reason = "ancestry chain too long"; return result; }
                int parentPid;
                if (!snapshot.ParentOf.TryGetValue(current.Pid, out parentPid)) { result.Reason = "parent edge missing"; return result; }
                if (parentPid <= 0 || parentPid == current.Pid || !visited.Add(parentPid)) { result.Reason = "parent edge loops or duplicates"; return result; }
                ProcessProbe parent = ProcessProbe.Open(parentPid);
                if (parent == null) { result.Reason = "parent process absent or unreadable"; return result; }
                held.Add(parent);
                if (parent.CreationTicks > current.CreationTicks) { result.Reason = "parent pid reused after child creation"; return result; }
                if (!parent.IsLive()) { result.Reason = "chain reached an exited parent before the target"; return result; }
                chain.Add(parentPid);
                result.Hops += 1;
                current = parent;
            }
        }

        /// <summary>Public containment probe used by the wrapper at admission time.</summary>
        public static AncestryProbe Probe(int descendantPid, string descendantStartUtc, int ancestorPid, string ancestorStartUtc)
        {
            long descendantTicks, ancestorTicks;
            if (!TryParseUtcTicks(descendantStartUtc, out descendantTicks) || !TryParseUtcTicks(ancestorStartUtc, out ancestorTicks))
            {
                return new AncestryProbe { Contained = false, Reason = "start identity unparseable" };
            }
            List<ProcessProbe> held = new List<ProcessProbe>();
            try
            {
                ProcessProbe descendant = ProcessProbe.Open(descendantPid);
                if (descendant == null) return new AncestryProbe { Contained = false, Reason = "descendant absent or unreadable" };
                held.Add(descendant);
                if (descendant.CreationTicks != descendantTicks) return new AncestryProbe { Contained = false, Reason = "descendant pid reused" };
                if (!descendant.IsLive()) return new AncestryProbe { Contained = false, Reason = "descendant exited" };
                HashSet<int> visited = new HashSet<int> { descendantPid };
                List<int> chain = new List<int> { descendantPid };
                Snapshot first = TakeSnapshot();
                AncestryProbe walk = WalkUp(first, descendant, ancestorPid, ancestorTicks, held, visited, chain);
                if (!walk.Contained) return walk;
                Snapshot second = TakeSnapshot();
                string recheck = RecheckChain(second, chain);
                if (recheck != null) return new AncestryProbe { Contained = false, Reason = recheck, Hops = walk.Hops };
                foreach (ProcessProbe probe in held)
                {
                    if (!probe.IsLive()) return new AncestryProbe { Contained = false, Reason = "chain member exited before reply", Hops = walk.Hops };
                }
                return walk;
            }
            finally
            {
                foreach (ProcessProbe probe in held) probe.Dispose();
            }
        }

        internal static string RecheckChain(Snapshot snapshot, List<int> chain)
        {
            if (snapshot.Unreadable) return "second process snapshot unreadable";
            if (snapshot.Duplicate) return "second process snapshot listed a duplicate pid";
            for (int index = 0; index + 1 < chain.Count; index += 1)
            {
                int parent;
                if (!snapshot.ParentOf.TryGetValue(chain[index], out parent) || parent != chain[index + 1])
                {
                    return "parent edge changed between snapshots";
                }
            }
            if (chain.Count > 0 && !snapshot.ParentOf.ContainsKey(chain[chain.Count - 1]))
            {
                return "ancestor missing from second snapshot";
            }
            return null;
        }
    }

    /// <summary>Everything the armed server compares each request against. Values are fixed at admission.</summary>
    public sealed class NestedOwnerBinding
    {
        public bool HostVerifier;
        public string OwnerRaw;
        public string LockDirectory;
        public string LockId;
        public string OwnerIdentity;
        public string Gate;
        public string State;
        public string CommandIdentity;
        public string[] AllowedKinds;
        public int WrapperPid;
        public string WrapperStartUtc;
        public int RootPid;
        public string RootStartUtc;
        public string Lane;
        public string Worktree;
        public string Branch;
        public string Head;
        public string IdentityMode;
        public string DispatchRecordPath;
        public string DispatchRecordRaw;
        public string LaunchId;
        public string LaneRole;
        public int DispatchLauncherPid;
        public string DispatchLauncherStartUtc;
        public int DispatchChildPid;
        public string DispatchChildStartUtc;
    }

    public sealed class NestedOwnerStatistics
    {
        public long Served;
        public long Refused;
        public long Connections;
        public string LastRefusal;
        public string LastError;
        public bool ThreadAlive;
        public double LastServiceMs;
        public double TotalServiceMs;
    }

    public sealed class NestedOwnerServer : IDisposable
    {
        public const int MaxRequestBytes = 16384;
        public const int ExchangeTimeoutMs = 5000;
        private static readonly Regex TransitionName = new Regex("^owner\\.transition\\.[a-f0-9]{32}\\.tmp$", RegexOptions.CultureInvariant);
        private static readonly Regex HexToken = new Regex("^[a-f0-9]{32}$", RegexOptions.CultureInvariant);
        private static readonly Regex HexChallenge = new Regex("^[a-f0-9]{64}$", RegexOptions.CultureInvariant);
        private static readonly Regex HexHead = new Regex("^[a-f0-9]{40}$", RegexOptions.CultureInvariant);
        private static readonly Regex LaunchIdShape = new Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", RegexOptions.CultureInvariant);
        private static readonly Regex LaneShape = new Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", RegexOptions.CultureInvariant);
        private static readonly string[] Kinds = { "repository-gate", "playwright", "vitest-full", "script-battery", "build" };
        private static readonly string[] RequestFields =
        {
            "schemaVersion", "challenge", "pid", "kind", "lockId",
            "lane", "worktree", "branch", "head", "identityMode", "gate", "launchId", "laneRole"
        };

        private readonly object _gate = new object();
        private readonly SafePipeHandle _handle;
        private readonly NamedPipeServerStream _pipe;
        private readonly ECDsa _key;
        private readonly CancellationTokenSource _stop = new CancellationTokenSource();
        private readonly NestedOwnerStatistics _statistics = new NestedOwnerStatistics();
        private NestedOwnerBinding _binding;
        private byte[] _ownerRawBytes;
        private byte[] _dispatchRawBytes;
        private Thread _thread;
        private bool _disposed;
        private readonly HashSet<string> _challenges = new HashSet<string>(StringComparer.Ordinal);

        private NestedOwnerServer(string lockId, SafePipeHandle handle, NamedPipeServerStream pipe, ECDsa key, string pipeName)
        {
            LockId = lockId;
            _handle = handle;
            _pipe = pipe;
            _key = key;
            PipeName = pipeName;
            PublicKey = Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());
        }

        public string LockId { get; private set; }
        public string PipeName { get; private set; }
        /// <summary>SubjectPublicKeyInfo (DER, base64) of the wrapper-only signing key.</summary>
        public string PublicKey { get; private set; }

        public static string PipeNameFor(string lockId)
        {
            return "\\\\.\\pipe\\chase-sets-heavy-" + lockId;
        }

        /// <summary>
        /// Reserves the single lifetime pipe instance for this lock id with a
        /// current-user-only DACL, first-instance and remote-client rejection,
        /// non-inheritable handle and overlapped I/O, and generates the
        /// wrapper-only signing key. No request is served until Arm.
        /// </summary>
        public static NestedOwnerServer Reserve(string lockId)
        {
            if (lockId == null || !HexToken.IsMatch(lockId)) throw new ArgumentException("lockId must be 32 lowercase hex characters");
            string pipeName = PipeNameFor(lockId);
            string sid = WindowsIdentity.GetCurrent().User.Value;
            RawSecurityDescriptor descriptor = new RawSecurityDescriptor("O:" + sid + "G:" + sid + "D:(A;;GA;;;" + sid + ")");
            byte[] descriptorBytes = new byte[descriptor.BinaryLength];
            descriptor.GetBinaryForm(descriptorBytes, 0);
            GCHandle pinned = GCHandle.Alloc(descriptorBytes, GCHandleType.Pinned);
            SafePipeHandle handle;
            try
            {
                Native.SECURITY_ATTRIBUTES attributes = new Native.SECURITY_ATTRIBUTES
                {
                    nLength = Marshal.SizeOf(typeof(Native.SECURITY_ATTRIBUTES)),
                    lpSecurityDescriptor = pinned.AddrOfPinnedObject(),
                    bInheritHandle = false
                };
                handle = Native.CreateNamedPipeW(
                    pipeName,
                    Native.PIPE_ACCESS_DUPLEX | Native.FILE_FLAG_FIRST_PIPE_INSTANCE | Native.FILE_FLAG_OVERLAPPED,
                    Native.PIPE_TYPE_BYTE | Native.PIPE_READMODE_BYTE | Native.PIPE_WAIT | Native.PIPE_REJECT_REMOTE_CLIENTS,
                    1,
                    (uint)(MaxRequestBytes * 2),
                    (uint)(MaxRequestBytes * 2),
                    0,
                    ref attributes);
                int error = Marshal.GetLastWin32Error();
                if (handle == null || handle.IsInvalid)
                {
                    throw new IOException("CreateNamedPipeW refused the reserved nested-owner instance (win32 error " + error + ")");
                }
            }
            finally
            {
                pinned.Free();
            }
            NamedPipeServerStream pipe;
            try
            {
                pipe = new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
            ECDsa key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            return new NestedOwnerServer(lockId, handle, pipe, key, pipeName);
        }

        /// <summary>Starts serving with the admission-time binding. Callable once.</summary>
        public void Arm(NestedOwnerBinding binding)
        {
            if (binding == null) throw new ArgumentNullException("binding");
            lock (_gate)
            {
                if (_disposed) throw new ObjectDisposedException("NestedOwnerServer");
                if (_thread != null) throw new InvalidOperationException("nested owner already armed");
                ValidateBinding(binding);
                _binding = binding;
                _ownerRawBytes = new UTF8Encoding(false).GetBytes(binding.OwnerRaw);
                _dispatchRawBytes = binding.DispatchRecordRaw == null ? null : new UTF8Encoding(false).GetBytes(binding.DispatchRecordRaw);
                _thread = new Thread(ServeLoop);
                _thread.IsBackground = true;
                _thread.Name = "chase-sets-nested-owner";
                _thread.Start();
            }
        }

        private static void ValidateBinding(NestedOwnerBinding binding)
        {
            if (string.IsNullOrEmpty(binding.OwnerRaw)) throw new ArgumentException("binding.OwnerRaw");
            if (string.IsNullOrEmpty(binding.LockDirectory)) throw new ArgumentException("binding.LockDirectory");
            if (binding.LockId == null || !HexToken.IsMatch(binding.LockId)) throw new ArgumentException("binding.LockId");
            if (binding.AllowedKinds == null) throw new ArgumentException("binding.AllowedKinds");
            foreach (string kind in binding.AllowedKinds)
            {
                if (Array.IndexOf(Kinds, kind) < 0) throw new ArgumentException("binding.AllowedKinds contains an unknown kind");
            }
            if (binding.WrapperPid <= 0 || binding.RootPid <= 0) throw new ArgumentException("binding pids");
            long ticks;
            if (!ProcessTree.TryParseUtcTicks(binding.WrapperStartUtc, out ticks) || !ProcessTree.TryParseUtcTicks(binding.RootStartUtc, out ticks))
            {
                throw new ArgumentException("binding start identities");
            }
            if (binding.State != "started" && binding.State != "attached") throw new ArgumentException("binding.State");
            if (binding.IdentityMode != "branch" && binding.IdentityMode != "immutable-head") throw new ArgumentException("binding.IdentityMode");
            if (binding.Head == null || !HexHead.IsMatch(binding.Head)) throw new ArgumentException("binding.Head");
            if (binding.IdentityMode == "branch" && string.IsNullOrEmpty(binding.Branch)) throw new ArgumentException("binding.Branch");
            if (binding.IdentityMode == "immutable-head" && binding.Branch != null) throw new ArgumentException("binding.Branch must be null");
            if (binding.Lane == null || !LaneShape.IsMatch(binding.Lane)) throw new ArgumentException("binding.Lane");
            if (binding.HostVerifier && (binding.State != "started" || binding.DispatchRecordRaw != null ||
                binding.LaunchId != null || binding.LaneRole != null ||
                Array.IndexOf(new[] { "verify:static", "check:static", "test:scripts", "verify:test", "test", "test:fast", "build", "verify", "verify:build", "verify:test-db", "test:e2e:suite" }, binding.Gate) < 0))
                throw new ArgumentException("host verifier requires a closed Gate launch, not a dispatch or Attach");
            if (string.IsNullOrEmpty(binding.Worktree) || !Path.IsPathFullyQualified(binding.Worktree)) throw new ArgumentException("binding.Worktree");
            if (binding.DispatchRecordRaw != null)
            {
                if (string.IsNullOrEmpty(binding.DispatchRecordPath)) throw new ArgumentException("binding.DispatchRecordPath");
                if (binding.LaunchId == null || !LaunchIdShape.IsMatch(binding.LaunchId)) throw new ArgumentException("binding.LaunchId");
                if (binding.LaneRole != "implementation" && binding.LaneRole != "review") throw new ArgumentException("binding.LaneRole");
                if (binding.DispatchLauncherPid <= 0 || binding.DispatchChildPid <= 0) throw new ArgumentException("binding dispatch pids");
                if (!ProcessTree.TryParseUtcTicks(binding.DispatchLauncherStartUtc, out ticks) || !ProcessTree.TryParseUtcTicks(binding.DispatchChildStartUtc, out ticks))
                {
                    throw new ArgumentException("binding dispatch start identities");
                }
            }
        }

        public NestedOwnerStatistics Statistics()
        {
            lock (_gate)
            {
                return new NestedOwnerStatistics
                {
                    Served = _statistics.Served,
                    Refused = _statistics.Refused,
                    Connections = _statistics.Connections,
                    LastRefusal = _statistics.LastRefusal,
                    LastError = _statistics.LastError,
                    ThreadAlive = _thread != null && _thread.IsAlive,
                    LastServiceMs = _statistics.LastServiceMs,
                    TotalServiceMs = _statistics.TotalServiceMs
                };
            }
        }

        /// <summary>Stops serving, closes the reserved instance and destroys the private key.</summary>
        public void Stop()
        {
            Thread thread;
            lock (_gate)
            {
                if (_disposed) return;
                _disposed = true;
                thread = _thread;
                _stop.Cancel();
            }
            try { _pipe.Dispose(); } catch { }
            try { _handle.Dispose(); } catch { }
            if (thread != null && thread.IsAlive) thread.Join(ExchangeTimeoutMs);
            try { _key.Dispose(); } catch { }
        }

        public void Dispose()
        {
            Stop();
        }

        private void ServeLoop()
        {
            int consecutiveFailures = 0;
            while (!_stop.IsCancellationRequested)
            {
                try
                {
                    _pipe.WaitForConnectionAsync(_stop.Token).GetAwaiter().GetResult();
                }
                catch (Exception)
                {
                    if (_stop.IsCancellationRequested) return;
                    consecutiveFailures += 1;
                    try { if (_pipe.IsConnected) _pipe.Disconnect(); } catch { }
                    if (consecutiveFailures > 64) return;
                    Thread.Sleep(10);
                    continue;
                }
                consecutiveFailures = 0;
                lock (_gate) { _statistics.Connections += 1; }
                System.Diagnostics.Stopwatch watch = System.Diagnostics.Stopwatch.StartNew();
                try
                {
                    ServeConnection();
                }
                catch (Exception error)
                {
                    lock (_gate)
                    {
                        _statistics.Refused += 1;
                        _statistics.LastError = error.GetType().Name + ": " + error.Message;
                    }
                }
                finally
                {
                    watch.Stop();
                    lock (_gate)
                    {
                        _statistics.LastServiceMs = watch.Elapsed.TotalMilliseconds;
                        _statistics.TotalServiceMs += watch.Elapsed.TotalMilliseconds;
                    }
                    try { _pipe.Disconnect(); } catch { }
                }
            }
        }

        private void ServeConnection()
        {
            using (CancellationTokenSource exchange = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token))
            {
                exchange.CancelAfter(ExchangeTimeoutMs);
                byte[] buffer = new byte[MaxRequestBytes + 1];
                int total = 0;
                int newline = -1;
                while (newline < 0)
                {
                    int read = _pipe.ReadAsync(buffer, total, buffer.Length - total, exchange.Token).GetAwaiter().GetResult();
                    if (read <= 0)
                    {
                        Refuse(exchange.Token, "request ended before its newline");
                        return;
                    }
                    int found = Array.IndexOf(buffer, (byte)'\n', total, read);
                    total += read;
                    if (found >= 0)
                    {
                        if (found != total - 1)
                        {
                            Refuse(exchange.Token, "request carried bytes after its newline");
                            return;
                        }
                        newline = found;
                        break;
                    }
                    if (total > MaxRequestBytes)
                    {
                        Refuse(exchange.Token, "request exceeded 16 KiB");
                        return;
                    }
                }
                if (total > MaxRequestBytes) { Refuse(exchange.Token, "request exceeded 16 KiB"); return; }
                Evaluate(buffer, newline, exchange.Token);
            }
        }

        private void Refuse(CancellationToken token, string reason)
        {
            lock (_gate)
            {
                _statistics.Refused += 1;
                _statistics.LastRefusal = reason;
            }
            byte[] message = Encoding.UTF8.GetBytes("{\"accepted\":false,\"message\":" + JsonSerializer.Serialize("nested continuation refused: " + reason) + "}\n");
            Reply(token, message);
        }

        private void Reply(CancellationToken token, byte[] bytes)
        {
            _pipe.WriteAsync(bytes, 0, bytes.Length, token).GetAwaiter().GetResult();
            _pipe.FlushAsync(token).GetAwaiter().GetResult();
            // DisconnectNamedPipe discards unread data, so hold the connection
            // until the client has consumed the reply and closed its end.
            byte[] drain = new byte[64];
            try
            {
                while (true)
                {
                    int read = _pipe.ReadAsync(drain, 0, drain.Length, token).GetAwaiter().GetResult();
                    if (read <= 0) break;
                }
            }
            catch (IOException) { }
            catch (OperationCanceledException) { }
        }

        private sealed class Request
        {
            public string Challenge;
            public int Pid;
            public string Kind;
            public string LockId;
            public string Lane;
            public string Worktree;
            public string Branch;
            public string Head;
            public string IdentityMode;
            public string Gate;
            public string LaunchId;
            public string LaneRole;
        }

        private static string StringOrNull(JsonElement element, bool allowNull, out bool ok)
        {
            ok = true;
            if (element.ValueKind == JsonValueKind.String) return element.GetString();
            if (allowNull && element.ValueKind == JsonValueKind.Null) return null;
            ok = false;
            return null;
        }

        private static bool TryReadInt(JsonElement element, out int value)
        {
            value = 0;
            if (element.ValueKind != JsonValueKind.Number) return false;
            long wide;
            if (!element.TryGetInt64(out wide)) return false;
            if (wide < 0 || wide > int.MaxValue) return false;
            // Reject 1.0 and 1e0 spellings: the raw text must be plain digits.
            string raw = element.GetRawText();
            foreach (char character in raw)
            {
                if (character < '0' || character > '9') return false;
            }
            value = (int)wide;
            return true;
        }

        private static Request ParseRequest(byte[] buffer, int length, out string failure)
        {
            failure = null;
            JsonDocument document;
            try
            {
                document = JsonDocument.Parse(new ReadOnlyMemory<byte>(buffer, 0, length), new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 4
                });
            }
            catch (JsonException)
            {
                failure = "request was not valid JSON";
                return null;
            }
            using (document)
            {
                JsonElement root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object) { failure = "request was not a JSON object"; return null; }
                Dictionary<string, JsonElement> fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
                foreach (JsonProperty property in root.EnumerateObject())
                {
                    if (fields.ContainsKey(property.Name)) { failure = "request repeated a field"; return null; }
                    if (Array.IndexOf(RequestFields, property.Name) < 0) { failure = "request carried an unknown field"; return null; }
                    fields[property.Name] = property.Value.Clone();
                }
                if (fields.Count != RequestFields.Length) { failure = "request omitted a required field"; return null; }
                int schemaVersion;
                if (!TryReadInt(fields["schemaVersion"], out schemaVersion) || schemaVersion != 1) { failure = "request schema version was not 1"; return null; }
                Request request = new Request();
                bool ok;
                request.Challenge = StringOrNull(fields["challenge"], false, out ok);
                if (!ok || !HexChallenge.IsMatch(request.Challenge)) { failure = "request challenge was not 32 bytes of lowercase hex"; return null; }
                if (!TryReadInt(fields["pid"], out request.Pid) || request.Pid <= 0) { failure = "request pid was not a positive integer"; return null; }
                request.Kind = StringOrNull(fields["kind"], false, out ok);
                if (!ok || Array.IndexOf(Kinds, request.Kind) < 0) { failure = "request kind was not a classified heavy kind"; return null; }
                request.LockId = StringOrNull(fields["lockId"], false, out ok);
                if (!ok || !HexToken.IsMatch(request.LockId)) { failure = "request lockId was malformed"; return null; }
                request.Lane = StringOrNull(fields["lane"], false, out ok);
                if (!ok || !LaneShape.IsMatch(request.Lane)) { failure = "request lane was malformed"; return null; }
                request.Worktree = StringOrNull(fields["worktree"], false, out ok);
                if (!ok || string.IsNullOrEmpty(request.Worktree)) { failure = "request worktree was malformed"; return null; }
                request.Branch = StringOrNull(fields["branch"], true, out ok);
                if (!ok) { failure = "request branch was malformed"; return null; }
                request.Head = StringOrNull(fields["head"], false, out ok);
                if (!ok || !HexHead.IsMatch(request.Head)) { failure = "request head was malformed"; return null; }
                request.IdentityMode = StringOrNull(fields["identityMode"], false, out ok);
                if (!ok || (request.IdentityMode != "branch" && request.IdentityMode != "immutable-head")) { failure = "request identityMode was malformed"; return null; }
                request.Gate = StringOrNull(fields["gate"], false, out ok);
                if (!ok || string.IsNullOrEmpty(request.Gate)) { failure = "request gate was malformed"; return null; }
                request.LaunchId = StringOrNull(fields["launchId"], true, out ok);
                if (!ok || (request.LaunchId != null && !LaunchIdShape.IsMatch(request.LaunchId))) { failure = "request launchId was malformed"; return null; }
                request.LaneRole = StringOrNull(fields["laneRole"], true, out ok);
                if (!ok) { failure = "request laneRole was malformed"; return null; }
                return request;
            }
        }

        private static bool SamePath(string left, string right)
        {
            try
            {
                return string.Equals(
                    Path.GetFullPath(left).TrimEnd('\\', '/'),
                    Path.GetFullPath(right).TrimEnd('\\', '/'),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static bool IsReparsePoint(string path)
        {
            try
            {
                return (File.GetAttributes(path) & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint;
            }
            catch
            {
                return true;
            }
        }

        /// <summary>Writer contract: owner.json alone, or owner.json beside exactly one regular transition file.</summary>
        private static string CheckWriterEntries(string lockDirectory)
        {
            if (!Directory.Exists(lockDirectory) || IsReparsePoint(lockDirectory)) return "lock directory absent or unsafe";
            string[] entries = Directory.GetFileSystemEntries(lockDirectory);
            if (entries.Length == 1) return Path.GetFileName(entries[0]) == "owner.json" ? null : "lock directory holds an unknown entry";
            if (entries.Length != 2) return "lock directory holds unexpected entries";
            string transition = null;
            bool ownerSeen = false;
            foreach (string entry in entries)
            {
                string name = Path.GetFileName(entry);
                if (name == "owner.json") { ownerSeen = true; continue; }
                transition = entry;
            }
            if (!ownerSeen || transition == null) return "lock directory lacks owner.json";
            if (!TransitionName.IsMatch(Path.GetFileName(transition))) return "lock directory holds an unknown writer entry";
            if (File.Exists(transition))
            {
                if (IsReparsePoint(transition)) return "transition entry is not a regular file";
                try {
                    if (!BytesEqual(File.ReadAllBytes(transition), File.ReadAllBytes(Path.Combine(lockDirectory, "owner.json"))))
                        return "transition conflicts with the unchanged admitted owner";
                } catch { return "transition content is unreadable"; }
                return null;
            }
            if (Directory.Exists(transition)) return "transition entry is a directory";
            // The writer completed its atomic move after the directory read.
            string[] current = Directory.GetFileSystemEntries(lockDirectory);
            return current.Length == 1 && Path.GetFileName(current[0]) == "owner.json" ? null : "lock directory changed during writer transition";
        }

        private static bool BytesEqual(byte[] left, byte[] right)
        {
            if (left == null || right == null || left.Length != right.Length) return false;
            for (int index = 0; index < left.Length; index += 1)
            {
                if (left[index] != right[index]) return false;
            }
            return true;
        }

        private static string ReadOwnerField(JsonElement owner, string name)
        {
            JsonElement value;
            if (!owner.TryGetProperty(name, out value)) return null;
            if (value.ValueKind == JsonValueKind.String) return value.GetString();
            if (value.ValueKind == JsonValueKind.Number) return value.GetRawText();
            if (value.ValueKind == JsonValueKind.Null) return null;
            return value.GetRawText();
        }

        /// <summary>Owner record re-read: byte-exact, closed, and consistent with every bound identity.</summary>
        private string CheckOwnerRecord(NestedOwnerBinding binding)
        {
            string entries = CheckWriterEntries(binding.LockDirectory);
            if (entries != null) return entries;
            string ownerPath = Path.Combine(binding.LockDirectory, "owner.json");
            if (!File.Exists(ownerPath) || IsReparsePoint(ownerPath)) return "owner.json absent or unsafe";
            byte[] raw;
            try { raw = File.ReadAllBytes(ownerPath); } catch { return "owner.json unreadable"; }
            if (!BytesEqual(raw, _ownerRawBytes)) return "owner.json no longer equals the admitted record";
            try
            {
                using (JsonDocument document = JsonDocument.Parse(raw))
                {
                    JsonElement owner = document.RootElement;
                    if (owner.ValueKind != JsonValueKind.Object) return "owner.json is not an object";
                    if (ReadOwnerField(owner, "lockId") != binding.LockId) return "owner lockId mismatch";
                    string state = ReadOwnerField(owner, "state");
                    if (state != binding.State || (state != "started" && state != "attached")) return "owner state is not started or attached";
                    if (ReadOwnerField(owner, "gate") != binding.Gate) return "owner gate mismatch";
                    if (ReadOwnerField(owner, "commandIdentity") != binding.CommandIdentity) return "owner commandIdentity mismatch";
                    if (ReadOwnerField(owner, "pid") != binding.WrapperPid.ToString(CultureInfo.InvariantCulture)) return "owner pid mismatch";
                    long expected, actual;
                    if (!ProcessTree.TryParseUtcTicks(ReadOwnerField(owner, "processStartUtc"), out actual) ||
                        !ProcessTree.TryParseUtcTicks(binding.WrapperStartUtc, out expected) || actual != expected) return "owner processStartUtc mismatch";
                    if (ReadOwnerField(owner, "childPid") != binding.RootPid.ToString(CultureInfo.InvariantCulture)) return "owner childPid mismatch";
                    if (!ProcessTree.TryParseUtcTicks(ReadOwnerField(owner, "childProcessStartUtc"), out actual) ||
                        !ProcessTree.TryParseUtcTicks(binding.RootStartUtc, out expected) || actual != expected) return "owner childProcessStartUtc mismatch";
                    if (ReadOwnerField(owner, "lane") != binding.Lane) return "owner lane mismatch";
                    if (!SamePath(ReadOwnerField(owner, "worktree") ?? string.Empty, binding.Worktree)) return "owner worktree mismatch";
                    if (ReadOwnerField(owner, "branch") != binding.Branch) return "owner branch mismatch";
                    if (ReadOwnerField(owner, "head") != binding.Head) return "owner head mismatch";
                    if (ReadOwnerField(owner, "identityMode") != binding.IdentityMode) return "owner identityMode mismatch";
                    if (ReadOwnerField(owner, "owner") != binding.OwnerIdentity) return "owner identity mismatch";
                }
            }
            catch (JsonException)
            {
                return "owner.json is not valid JSON";
            }
            return null;
        }

        /// <summary>Dispatch ownership record re-read: byte-exact, launcher not reused, child live and exact.</summary>
        private string CheckDispatchRecord(NestedOwnerBinding binding, List<ProcessProbe> held, out ProcessProbe dispatchChild)
        {
            dispatchChild = null;
            if (_dispatchRawBytes == null) return "admission has no provable dispatch binding";
            if (!File.Exists(binding.DispatchRecordPath) || IsReparsePoint(binding.DispatchRecordPath)) return "dispatch record absent or unsafe";
            byte[] raw;
            try { raw = ReadBoundedFile(binding.DispatchRecordPath, 65536); } catch { return "dispatch record unreadable or unsafe"; }
            if (!BytesEqual(raw, _dispatchRawBytes)) return "dispatch record changed since admission";
            Dictionary<string, byte[]> currentCensus;
            try { currentCensus = CaptureDispatchCensus(Path.GetDirectoryName(binding.DispatchRecordPath)); }
            catch (Exception error) { return "dispatch census unknown: " + error.Message; }
            string censusFailure = CheckDispatchCensus(currentCensus, binding.DispatchRecordPath,
                _dispatchRawBytes, binding.Worktree, Path.GetTempPath());
            if (censusFailure != null) return "dispatch census changed or is unknown since admission: " + censusFailure;
            long launcherTicks, childTicks;
            ProcessTree.TryParseUtcTicks(binding.DispatchLauncherStartUtc, out launcherTicks);
            ProcessTree.TryParseUtcTicks(binding.DispatchChildStartUtc, out childTicks);
            // The reader treats a started record's child as the owner; the
            // launcher may already have exited, but its pid must not be reused.
            ProcessProbe launcher = ProcessProbe.Open(binding.DispatchLauncherPid);
            if (launcher != null)
            {
                bool launcherLive = launcher.IsLive();
                if (launcherLive && launcher.CreationTicks != launcherTicks) { launcher.Dispose(); return "dispatch launcher pid reused"; }
                if (launcherLive) held.Add(launcher); else launcher.Dispose();
            }
            ProcessProbe child = ProcessProbe.Open(binding.DispatchChildPid);
            if (child == null) return "dispatch child absent or unreadable";
            held.Add(child);
            if (child.CreationTicks != childTicks) return "dispatch child pid reused";
            if (!child.IsLive()) return "dispatch child exited";
            dispatchChild = child;
            return null;
        }

        // Capture one bounded complete input set. Semantic ownership is refreshed
        // from these bytes at admission and on every request, including unchanged
        // rows whose process, Git identity or transcript may have changed.
        public static Dictionary<string, byte[]> CaptureDispatchCensus(string runtimeRoot)
        {
            var result = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            if (!SafePath(runtimeRoot)) throw new IOException("dispatch census root unsafe");
            long bytes = 0;
            foreach (string path in Directory.EnumerateFileSystemEntries(runtimeRoot, "dispatch-launch-*.json")) {
                if (result.Count >= 64) throw new IOException("dispatch census unknown or truncated");
                byte[] raw = ReadBoundedFile(path, 65536);
                bytes += raw.Length;
                if (bytes > 1048576) throw new IOException("dispatch census byte bound exceeded");
                result.Add(path, raw);
            }
            return result;
        }


        private static bool SafePath(string path)
        {
            try {
                for (string current = Path.GetFullPath(path); current != null; current = Path.GetDirectoryName(current))
                    if (IsReparsePoint(current)) return false;
                return true;
            } catch { return false; }
        }

        private static SafeFileHandle OpenCensusPath(string path, bool directory)
        {
            if (!SafePath(path)) throw new IOException("unsafe census path");
            // OPEN_REPARSE_POINT also checks the opened object, closing the
            // final-component check/open race without following a link.
            SafeFileHandle handle = Native.CreateFileW(path, directory ? 0U : 0x80000000U, 7,
                IntPtr.Zero, 3, 0x00200000U | (directory ? 0x02000000U : 0U), IntPtr.Zero);
            Native.FILE_ATTRIBUTE_TAG_INFO info;
            if (handle.IsInvalid || !Native.GetFileInformationByHandleEx(handle, 9, out info, 8) ||
                (info.Attributes & 0x400U) != 0 || ((info.Attributes & 0x10U) != 0) != directory) {
                handle.Dispose(); throw new IOException("census path absent, unreadable or unsafe");
            }
            return handle;
        }

        private static byte[] ReadBoundedFile(string path, int bound)
        {
            using (SafeFileHandle handle = OpenCensusPath(path, false))
            using (FileStream stream = new FileStream(handle, FileAccess.Read)) {
                long length = stream.Length;
                if (length > bound) throw new IOException("dispatch record byte bound exceeded");
                byte[] bytes = new byte[(int)length];
                int offset = 0;
                while (offset < bytes.Length) {
                    int read = stream.Read(bytes, offset, bytes.Length - offset);
                    if (read == 0) throw new IOException("census read incomplete");
                    offset += read;
                }
                if (stream.Length != length) throw new IOException("census read changed length");
                return bytes;
            }
        }

        private static string CanonicalDirectory(string path)
        {
            using (SafeFileHandle handle = OpenCensusPath(path, true)) {
                StringBuilder result = new StringBuilder(32768);
                uint size = Native.GetFinalPathNameByHandleW(handle, result, (uint)result.Capacity, 0);
                if (size == 0 || size >= result.Capacity) throw new IOException("canonical census path unknown");
                string value = result.ToString();
                if (value.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) value = @"\\" + value.Substring(8);
                else if (value.StartsWith(@"\\?\", StringComparison.Ordinal)) value = value.Substring(4);
                return value.TrimEnd('\\', '/');
            }
        }

        private static string DispatchString(JsonElement record, string name)
        {
            JsonElement value = record.GetProperty(name);
            if (value.ValueKind != JsonValueKind.String) throw new IOException("dispatch field type: " + name);
            return value.GetString();
        }

        private static int DispatchPid(JsonElement record, string name)
        {
            JsonElement value = record.GetProperty(name);
            int pid;
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out pid) || pid <= 0)
                throw new IOException("dispatch process field: " + name);
            return pid;
        }

        private static long DispatchTime(JsonElement record, string name)
        {
            long ticks;
            if (!ProcessTree.TryParseUtcTicks(DispatchString(record, name), out ticks))
                throw new IOException("dispatch time field: " + name);
            return ticks;
        }

        private static bool DispatchRoutingProvenance(JsonElement record, HashSet<string> fields)
        {
            string[] names = { "policyGeneration", "registryAuthorityDigest", "family", "slot", "usedLastKnownGood" };
            int present = 0;
            foreach (string name in names) if (fields.Contains(name)) present++;
            if (present == 0) return true;
            if (present != names.Length) return false;

            JsonElement policyGeneration = record.GetProperty("policyGeneration");
            int generation;
            if (policyGeneration.ValueKind != JsonValueKind.Number ||
                !policyGeneration.TryGetInt32(out generation) || generation < 1) return false;
            JsonElement registryAuthorityDigest = record.GetProperty("registryAuthorityDigest");
            if (registryAuthorityDigest.ValueKind != JsonValueKind.String ||
                !Regex.IsMatch(registryAuthorityDigest.GetString(), "^[a-zA-Z0-9._:-]{1,128}$")) return false;
            JsonElement family = record.GetProperty("family");
            if (family.ValueKind != JsonValueKind.String ||
                !Regex.IsMatch(family.GetString(), "^[a-z0-9][a-z0-9._-]{0,63}$")) return false;
            JsonElement slot = record.GetProperty("slot");
            if (slot.ValueKind != JsonValueKind.String ||
                !Regex.IsMatch(slot.GetString(), "^(explicit|(codex|claude)\\.(primary|fallback))$")) return false;
            JsonElement usedLastKnownGood = record.GetProperty("usedLastKnownGood");
            return usedLastKnownGood.ValueKind == JsonValueKind.True ||
                usedLastKnownGood.ValueKind == JsonValueKind.False;
        }

        // Same closed ownership-v4, process/Git confinement, duplicate and
        // bounded transcript semantics as Get-LiveDispatchOwnership. This is
        // the native request boundary; it never invokes a per-child host.
        public static string CheckDispatchCensus(Dictionary<string, byte[]> census, string selectedPath,
            byte[] selectedRaw, string selectedWorktree, string tempRoot)
        {
            try {
                byte[] selected;
                if (census == null || census.Count > 64 || !census.TryGetValue(selectedPath, out selected) ||
                    !BytesEqual(selectedRaw, selected)) return "selected dispatch absent or changed";
                string runtime = CanonicalDirectory(Path.GetDirectoryName(selectedPath));
                string container = CanonicalDirectory(Path.GetDirectoryName(runtime));
                string target = CanonicalDirectory(selectedWorktree);
                var worktrees = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var transcripts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                bool selectedLive = false;
                long total = 0;
                long started = Environment.TickCount64;
                foreach (var item in census) {
                    if (Environment.TickCount64 - started >= 5000) return "ownership-deadline-truncated";
                    total += item.Value.Length;
                    if (item.Value.Length == 0 || item.Value.Length > 65536 || total > 1048576)
                        return "dispatch census byte bound exceeded";
                    using (JsonDocument document = JsonDocument.Parse(item.Value)) {
                        JsonElement record = document.RootElement;
                        var fields = new HashSet<string>(StringComparer.Ordinal);
                        foreach (JsonProperty field in record.EnumerateObject())
                            if (!fields.Add(field.Name)) return "duplicate dispatch field";
                        string[] required = { "schemaVersion", "launchId", "laneRole", "promptPath", "reviewIsolationRoot",
                            "launcherPid", "launcherStartIdentity", "recordedAt", "state", "childPid", "childStartIdentity",
                            "worktree", "lane", "identityMode", "branch", "head", "label", "transcriptPath" };
                        string[] provenance = { "policyGeneration", "registryAuthorityDigest", "family", "slot", "usedLastKnownGood" };
                        int provenanceCount = 0;
                        foreach (string field in provenance) if (fields.Contains(field)) provenanceCount++;
                        if (provenanceCount != 0 && provenanceCount != provenance.Length) return "ownership-record-invalid";
                        if (fields.Count != required.Length + provenanceCount) return "ownership-record-invalid";
                        foreach (string field in required) if (!fields.Contains(field)) return "ownership-record-invalid";
                        if (!DispatchRoutingProvenance(record, fields)) return "ownership-record-invalid";
                        if (record.GetProperty("schemaVersion").ValueKind != JsonValueKind.Number ||
                            record.GetProperty("schemaVersion").GetInt32() != 4) return "ownership schema unknown";
                        string launch = DispatchString(record, "launchId"), role = DispatchString(record, "laneRole");
                        if (!Regex.IsMatch(launch, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") ||
                            !SamePath(item.Key, Path.Combine(runtime, "dispatch-launch-" + launch + ".json"))) return "dispatch launch path invalid";
                        string prompt = DispatchString(record, "promptPath");
                        if (!Path.IsPathFullyQualified(prompt) || !SamePath(prompt, Path.Combine(runtime, "dispatch-heavy-verifier-" + launch + ".prompt.txt"))) return "dispatch prompt invalid";
                        if (role == "implementation") {
                            if (record.GetProperty("reviewIsolationRoot").ValueKind != JsonValueKind.Null) return "dispatch isolation invalid";
                        } else if (role == "review" || role == "planning") {
                            string isolation = DispatchString(record, "reviewIsolationRoot");
                            if (!Path.IsPathFullyQualified(isolation) || !SamePath(isolation, Path.Combine(tempRoot, "chase-sets-" + role + "-" + launch))) return "dispatch isolation invalid";
                        } else return "dispatch role invalid";
                        int ownerPid = DispatchPid(record, "launcherPid");
                        long ownerTicks = DispatchTime(record, "launcherStartIdentity");
                        DispatchTime(record, "recordedAt");
                        string state = DispatchString(record, "state");
                        if (state == "started") { ownerPid = DispatchPid(record, "childPid"); ownerTicks = DispatchTime(record, "childStartIdentity"); }
                        else if (state != "launching" || record.GetProperty("childPid").ValueKind != JsonValueKind.Null ||
                            record.GetProperty("childStartIdentity").ValueKind != JsonValueKind.Null) return "dispatch state invalid";
                        string worktree = DispatchString(record, "worktree"), lane = DispatchString(record, "lane");
                        string mode = DispatchString(record, "identityMode"), head = DispatchString(record, "head");
                        if (!Path.IsPathFullyQualified(worktree) || !Regex.IsMatch(lane, "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$") ||
                            Path.GetFileName(Path.GetFullPath(worktree).TrimEnd('\\', '/')) != lane || !Regex.IsMatch(head, "^[a-f0-9]{40}$")) return "dispatch worktree identity invalid";
                        if (mode == "branch") {
                            string branch = DispatchString(record, "branch");
                            if (string.IsNullOrWhiteSpace(branch) || branch.Length > 512 || branch.Trim() != branch) return "dispatch branch invalid";
                        } else if (mode != "immutable-head" || record.GetProperty("branch").ValueKind != JsonValueKind.Null) return "dispatch mode invalid";
                        string label = DispatchString(record, "label"), transcript = DispatchString(record, "transcriptPath");
                        if (!Regex.IsMatch(label, "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$") || !Path.IsPathFullyQualified(transcript) ||
                            !SamePath(Path.GetDirectoryName(transcript), runtime) || Path.GetFileName(transcript) != label + ".jsonl") return "dispatch transcript binding invalid";
                        // Absence is proven by the complete native process snapshot;
                        // OpenProcess failure alone cannot distinguish dead from denied.
                        using (ProcessProbe owner = ProcessProbe.Open(ownerPid)) {
                            if (owner == null) {
                                ProcessTree.Snapshot snapshot = ProcessTree.TakeSnapshot();
                                if (snapshot.Unreadable || snapshot.Duplicate || snapshot.ParentOf.ContainsKey(ownerPid)) return "process-identity-probe-failed";
                                continue;
                            }
                            if (owner.CreationTicks != ownerTicks || !owner.IsLive()) continue;
                            try {
                                FileAttributes attributes = File.GetAttributes(worktree);
                                if ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) == 0)
                                    return "worktree-identity-probe-failed: unsafe worktree";
                            } catch (FileNotFoundException) { continue; }
                            catch (DirectoryNotFoundException) { continue; }
                            string canonical = CanonicalDirectory(worktree);
                            string canonicalLane = Path.GetFileName(canonical);
                            if (canonicalLane != lane || (lane.StartsWith("lane-", StringComparison.OrdinalIgnoreCase) && !Regex.IsMatch(lane, "^lane-[0-9]{2}$"))) return "malformed-live-lane-name";
                            if (!SamePath(Path.GetDirectoryName(canonical), container)) continue;
                            string currentBranch, currentHead;
                            if (!TryResolveGitIdentity(canonical, out currentBranch, out currentHead)) return "worktree-identity-probe-failed";
                            if (mode == "immutable-head" && (currentBranch != null || currentHead != head)) continue;
                            if (!worktrees.Add(canonical)) return "duplicate-live-ownership";
                            if (!transcripts.Add(Path.GetFullPath(transcript))) return "duplicate-live-transcript";
                            string attempt = DispatchAttemptState(transcript);
                            if (attempt == "unknown") return "transcript-state-unknown";
                            if (SamePath(canonical, target)) {
                                if (!SamePath(item.Key, selectedPath)) return "competing target dispatch";
                                if (state != "started" || (role != "implementation" && role != "review") || attempt != "active") return "selected dispatch is not active";
                                selectedLive = true;
                            }
                        }
                    }
                }
                return selectedLive ? null : "selected live ownership absent";
            } catch (Exception error) { return "dispatch census unknown: " + error.Message; }
        }

        private static string DispatchAttemptState(string path)
        {
            try {
                using (SafeFileHandle handle = OpenCensusPath(path, false))
                using (FileStream stream = new FileStream(handle, FileAccess.Read)) {
                    long length = stream.Length;
                    if (length == 0) return "active";
                    int count = (int)Math.Min(length, 1048576L);
                    long start = length - count;
                    stream.Seek(start, SeekOrigin.Begin);
                    byte[] bytes = new byte[count];
                    int offset = 0;
                    while (offset < count) {
                        int read = stream.Read(bytes, offset, count - offset);
                        if (read == 0) return "unknown";
                        offset += read;
                    }
                    int alignment = 0;
                    if (start > 0) while (alignment < Math.Min(3, count) && (bytes[alignment] & 0xc0) == 0x80) alignment++;
                    string text = Encoding.UTF8.GetString(bytes, alignment, count - alignment);
                    if (start > 0) {
                        int first = text.IndexOf('\n');
                        if (first < 0) return "unknown";
                        text = text.Substring(first + 1);
                    }
                    int cursor = text.LastIndexOf('\n') - 1, rows = 0, malformed = 0;
                    string state = "active";
                    while (cursor >= 0 && rows < 64) {
                        int previous = text.LastIndexOf('\n', cursor);
                        string row = text.Substring(previous + 1, cursor - previous).TrimEnd('\r');
                        cursor = previous - 1;
                        if (string.IsNullOrWhiteSpace(row)) continue;
                        rows++;
                        try {
                            if (Encoding.UTF8.GetByteCount(row) > 2103802) throw new IOException("transcript row bound");
                            using (JsonDocument document = JsonDocument.Parse(row)) {
                                JsonElement type;
                                if (rows == 1 && document.RootElement.ValueKind == JsonValueKind.Object &&
                                    document.RootElement.TryGetProperty("type", out type) && type.ValueKind == JsonValueKind.String &&
                                    (type.GetString() == "result" || type.GetString() == "turn.completed")) state = "terminal";
                            }
                        } catch { if (rows == 1) return "unknown"; malformed++; }
                    }
                    return malformed > 3 && malformed > 0.25 * rows ? "unknown" : state;
                }
            } catch { return "unknown"; }
        }

        /// <summary>Resolves HEAD and its ref in-process with closed formats; null means unknown.</summary>
        internal static bool TryResolveGitIdentity(string worktree, out string branch, out string head)
        {
            branch = null;
            head = null;
            try
            {
                string dotGit = Path.Combine(worktree, ".git");
                string gitDirectory;
                if (Directory.Exists(dotGit))
                {
                    if (IsReparsePoint(dotGit)) return false;
                    gitDirectory = dotGit;
                }
                else if (File.Exists(dotGit))
                {
                    if (IsReparsePoint(dotGit)) return false;
                    string pointer = File.ReadAllText(dotGit, Encoding.UTF8);
                    Match pointerMatch = Regex.Match(pointer, "^gitdir: ([^\\r\\n]+)\\r?\\n?$", RegexOptions.CultureInvariant);
                    if (!pointerMatch.Success) return false;
                    string target = pointerMatch.Groups[1].Value;
                    gitDirectory = Path.IsPathFullyQualified(target) ? target : Path.GetFullPath(Path.Combine(worktree, target));
                    if (!Directory.Exists(gitDirectory)) return false;
                }
                else
                {
                    return false;
                }
                string commonDirectory = gitDirectory;
                if (IsReparsePoint(gitDirectory)) return false;
                string commonPointer = Path.Combine(gitDirectory, "commondir");
                if (File.Exists(commonPointer))
                {
                    if (IsReparsePoint(commonPointer)) return false;
                    string common = File.ReadAllText(commonPointer, Encoding.UTF8);
                    Match commonMatch = Regex.Match(common, "^([^\\r\\n]+)\\r?\\n?$", RegexOptions.CultureInvariant);
                    if (!commonMatch.Success) return false;
                    string target = commonMatch.Groups[1].Value;
                    commonDirectory = Path.IsPathFullyQualified(target) ? target : Path.GetFullPath(Path.Combine(gitDirectory, target));
                    if (!Directory.Exists(commonDirectory)) return false;
                }
                if (IsReparsePoint(commonDirectory)) return false;
                string headPath = Path.Combine(gitDirectory, "HEAD");
                if (!File.Exists(headPath) || IsReparsePoint(headPath)) return false;
                string headText = File.ReadAllText(headPath, Encoding.UTF8);
                Match detached = Regex.Match(headText, "^([0-9a-f]{40})\\r?\\n?$", RegexOptions.CultureInvariant);
                if (detached.Success)
                {
                    head = detached.Groups[1].Value;
                    return true;
                }
                Match symbolic = Regex.Match(headText, "^ref: refs/heads/([^\\s]+)\\r?\\n?$", RegexOptions.CultureInvariant);
                if (!symbolic.Success) return false;
                string branchName = symbolic.Groups[1].Value;
                if (branchName.Contains("..") || branchName.Contains("@{") ||
                    Regex.IsMatch(branchName, "[~^:?*\\[\\\\\\x00-\\x20\\x7f]")) return false;
                foreach (string part in branchName.Split('/'))
                    if (part.Length == 0 || part.StartsWith(".") || part.EndsWith(".") || part.EndsWith(".lock")) return false;
                string refName = "refs/heads/" + branchName;
                string loosePath = Path.Combine(commonDirectory, "refs", "heads", branchName.Replace('/', Path.DirectorySeparatorChar));
                if (File.Exists(loosePath))
                {
                    if (IsReparsePoint(loosePath)) return false;
                    string looseText = File.ReadAllText(loosePath, Encoding.UTF8);
                    Match loose = Regex.Match(looseText, "^([0-9a-f]{40})\\r?\\n?$", RegexOptions.CultureInvariant);
                    if (!loose.Success) return false;
                    branch = branchName;
                    head = loose.Groups[1].Value;
                    return true;
                }
                string packedPath = Path.Combine(commonDirectory, "packed-refs");
                if (!File.Exists(packedPath) || IsReparsePoint(packedPath)) return false;
                string found = null;
                foreach (string line in File.ReadAllLines(packedPath, Encoding.UTF8))
                {
                    if (line.Length == 0 || line[0] == '#' || line[0] == '^') continue;
                    Match packed = Regex.Match(line, "^([0-9a-f]{40}) (.+)$", RegexOptions.CultureInvariant);
                    if (!packed.Success) return false;
                    if (packed.Groups[2].Value == refName)
                    {
                        if (found != null) return false;
                        found = packed.Groups[1].Value;
                    }
                }
                if (found == null) return false;
                branch = branchName;
                head = found;
                return true;
            }
            catch
            {
                branch = null;
                head = null;
                return false;
            }
        }

        private static string CheckGitIdentity(NestedOwnerBinding binding)
        {
            string branch, head;
            if (!TryResolveGitIdentity(binding.Worktree, out branch, out head)) return "live worktree Git identity is unknown";
            if (head != binding.Head) return "live worktree HEAD moved since admission";
            if (binding.IdentityMode == "branch")
            {
                if (branch == null || branch != binding.Branch) return "live worktree branch moved since admission";
            }
            else if (branch != null)
            {
                return "live worktree left its detached immutable head";
            }
            return null;
        }

        private byte[] Evaluate(byte[] buffer, int length, CancellationToken token)
        {
            NestedOwnerBinding binding;
            lock (_gate) { binding = _binding; }
            string failure;
            Request request = ParseRequest(buffer, length, out failure);
            if (request == null) { Refuse(token, failure); return null; }

            uint actualPid;
            if (!Native.GetNamedPipeClientProcessId(_handle, out actualPid)) { Refuse(token, "actual client pid unavailable"); return null; }
            if (actualPid != (uint)request.Pid) { Refuse(token, "request pid is not the actual pipe client"); return null; }

            List<ProcessProbe> held = new List<ProcessProbe>();
            try
            {
                // The server must still be the exact wrapper the owner record names.
                if (ProcessTree.CurrentProcessId() != (uint)binding.WrapperPid) { Refuse(token, "server process is not the exact wrapper"); return null; }
                ProcessProbe self = ProcessProbe.Open(binding.WrapperPid);
                long wrapperTicks;
                ProcessTree.TryParseUtcTicks(binding.WrapperStartUtc, out wrapperTicks);
                if (self == null || self.CreationTicks != wrapperTicks) { if (self != null) self.Dispose(); Refuse(token, "server process identity is not the exact wrapper"); return null; }
                held.Add(self);

                string ownerFailure = CheckOwnerRecord(binding);
                if (ownerFailure != null) { Refuse(token, ownerFailure); return null; }

                if (request.LockId != binding.LockId) { Refuse(token, "request lockId is not this owner"); return null; }
                if (request.Gate != binding.Gate) { Refuse(token, "request gate is not the admitted gate"); return null; }
                if (request.LaunchId != binding.LaunchId) { Refuse(token, "request launchId is not the admitted dispatch"); return null; }
                if (request.LaneRole != binding.LaneRole) { Refuse(token, "request laneRole is not the admitted role"); return null; }
                if (request.Lane != binding.Lane) { Refuse(token, "request lane is not the admitted lane"); return null; }
                if (!SamePath(request.Worktree, binding.Worktree)) { Refuse(token, "request worktree is not the admitted worktree"); return null; }
                if (request.Branch != binding.Branch) { Refuse(token, "request branch is not the admitted branch"); return null; }
                if (request.Head != binding.Head) { Refuse(token, "request head is not the admitted head"); return null; }
                if (request.IdentityMode != binding.IdentityMode) { Refuse(token, "request identityMode is not the admitted mode"); return null; }
                if (Array.IndexOf(binding.AllowedKinds, request.Kind) < 0) { Refuse(token, "request kind " + request.Kind + " is not admitted under gate " + binding.Gate); return null; }

                if (!binding.HostVerifier) {
                    ProcessProbe dispatchChild;
                    string dispatchFailure = CheckDispatchRecord(binding, held, out dispatchChild);
                    if (dispatchFailure != null) { Refuse(token, dispatchFailure); return null; }
                }

                string gitFailure = CheckGitIdentity(binding);
                if (gitFailure != null) { Refuse(token, gitFailure); return null; }

                long rootTicks, dispatchChildTicks;
                ProcessTree.TryParseUtcTicks(binding.RootStartUtc, out rootTicks);
                ProcessTree.TryParseUtcTicks(binding.DispatchChildStartUtc, out dispatchChildTicks);
                ProcessProbe root = ProcessProbe.Open(binding.RootPid);
                if (root == null) { Refuse(token, "guarded root absent or unreadable"); return null; }
                held.Add(root);
                if (root.CreationTicks != rootTicks) { Refuse(token, "guarded root pid reused"); return null; }
                if (!root.IsLive()) { Refuse(token, "guarded root exited"); return null; }

                ProcessProbe client = ProcessProbe.Open(request.Pid);
                if (client == null) { Refuse(token, "actual client process unreadable"); return null; }
                held.Add(client);
                if (!client.IsLive()) { Refuse(token, "actual client process exited"); return null; }

                // Ancestry is the authority: actual client -> exact guarded root ->
                // bound dispatch child or host wrapper, every edge from one snapshot and every
                // member opened, ordered by creation, and live.
                ProcessTree.Snapshot first = ProcessTree.TakeSnapshot();
                HashSet<int> visited = new HashSet<int> { client.Pid };
                List<int> chain = new List<int> { client.Pid };
                AncestryProbe toRoot = ProcessTree.WalkUp(first, client, binding.RootPid, rootTicks, held, visited, chain);
                if (!toRoot.Contained) { Refuse(token, "client is not a live descendant of the guarded root (" + toRoot.Reason + ")"); return null; }
                AncestryProbe toDispatch = ProcessTree.WalkUp(first, root,
                    binding.HostVerifier ? binding.WrapperPid : binding.DispatchChildPid,
                    binding.HostVerifier ? wrapperTicks : dispatchChildTicks, held, visited, chain);
                if (!toDispatch.Contained) { Refuse(token, "guarded root is not inside the bound dispatch tree (" + toDispatch.Reason + ")"); return null; }

                ProcessTree.Snapshot second = ProcessTree.TakeSnapshot();
                string recheck = ProcessTree.RecheckChain(second, chain);
                if (recheck != null) { Refuse(token, recheck); return null; }

                // Immediately before the reply every held handle must still be non-signaled.
                foreach (ProcessProbe probe in held)
                {
                    if (!probe.IsLive()) { Refuse(token, "a process in the authority chain exited before the reply"); return null; }
                }

                byte[] reply = SignedReply(binding, request, client, root);
                if (_challenges.Count >= 65536 || !_challenges.Add(request.Challenge)) {
                    Refuse(token, "challenge replayed or lifetime challenge bound reached"); return null;
                }
                foreach (ProcessProbe probe in held)
                    if (!probe.IsLive()) { Refuse(token, "a process in the authority chain exited before the reply"); return null; }
                Reply(token, reply);
                lock (_gate) { _statistics.Served += 1; }
                return null;
            }
            finally
            {
                foreach (ProcessProbe probe in held) probe.Dispose();
            }
        }

        private byte[] SignedReply(NestedOwnerBinding binding, Request request, ProcessProbe client, ProcessProbe root)
        {
            byte[] payload;
            using (MemoryStream stream = new MemoryStream())
            {
                using (Utf8JsonWriter writer = new Utf8JsonWriter(stream))
                {
                    writer.WriteStartObject();
                    writer.WriteNumber("schemaVersion", binding.HostVerifier ? 2 : 1);
                    if (binding.HostVerifier) {
                        writer.WriteString("authority", "host-verifier");
                        writer.WriteString("commandIdentity", binding.CommandIdentity);
                    }
                    writer.WriteBoolean("accepted", true);
                    writer.WriteString("challenge", request.Challenge);
                    writer.WriteStartObject("client");
                    writer.WriteNumber("pid", client.Pid);
                    writer.WriteString("processStartUtc", client.CreationUtc);
                    writer.WriteEndObject();
                    writer.WriteStartObject("root");
                    writer.WriteNumber("pid", root.Pid);
                    writer.WriteString("processStartUtc", root.CreationUtc);
                    writer.WriteEndObject();
                    writer.WriteStartObject("wrapper");
                    writer.WriteNumber("pid", binding.WrapperPid);
                    writer.WriteString("processStartUtc", binding.WrapperStartUtc);
                    writer.WriteEndObject();
                    writer.WriteString("lockId", binding.LockId);
                    writer.WriteStartObject("dispatch");
                    writer.WriteString("launchId", binding.LaunchId);
                    writer.WriteString("laneRole", binding.LaneRole);
                    writer.WriteEndObject();
                    writer.WriteString("kind", request.Kind);
                    writer.WriteString("gate", binding.Gate);
                    writer.WriteString("lane", binding.Lane);
                    writer.WriteString("worktree", binding.Worktree);
                    if (binding.Branch == null) writer.WriteNull("branch"); else writer.WriteString("branch", binding.Branch);
                    writer.WriteString("head", binding.Head);
                    writer.WriteString("identityMode", binding.IdentityMode);
                    writer.WriteString("owner", binding.OwnerIdentity);
                    writer.WriteEndObject();
                }
                payload = stream.ToArray();
            }
            byte[] signature = _key.SignData(payload, HashAlgorithmName.SHA256);
            string envelope = "{\"payload\":\"" + Convert.ToBase64String(payload) + "\",\"signature\":\"" + Convert.ToBase64String(signature) + "\"}\n";
            return Encoding.UTF8.GetBytes(envelope);
        }
    }
}
