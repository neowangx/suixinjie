using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Suixinjie
{
    internal sealed class UpdateOffer
    {
        public readonly Version Version;
        public readonly Uri Download;
        public readonly string Digest;
        public readonly long Size;

        public UpdateOffer(Version version, Uri download, string digest, long size)
        {
            Version = version;
            Download = download;
            Digest = digest;
            Size = size;
        }
    }

    internal static class GitHubUpdater
    {
        public const string ReleasePage = "https://github.com/neowangx/suixinjie/releases";
        public const string AssetName = "Suixinjie-windows.zip";
        private const string StagePrefix = ".suixinjie-update-";
        private const string ExeName = "Suixinjie.exe";
        private const string ConfigName = "Suixinjie.exe.config";
        private const string HelperName = "apply.exe";
        private const int PackageLimit = 64 * 1024 * 1024;
        private static readonly Uri Endpoint = new Uri("https://api.github.com/repos/neowangx/suixinjie/releases/latest");
        private static readonly Lazy<HttpClient> Client = new Lazy<HttpClient>(() => new HttpClient(new HttpClientHandler
        {
            AllowAutoRedirect = false, UseCookies = false, SslProtocols = System.Security.Authentication.SslProtocols.Tls12
        }));

        [DataContract]
        private sealed class Release
        {
            [DataMember(Name = "tag_name", IsRequired = true)] public string Tag { get; set; }
            [DataMember(Name = "draft", IsRequired = true)] public bool Draft { get; set; }
            [DataMember(Name = "prerelease", IsRequired = true)] public bool Prerelease { get; set; }
            [DataMember(Name = "assets", IsRequired = true)] public Asset[] Assets { get; set; }
        }

        [DataContract]
        private sealed class Asset
        {
            [DataMember(Name = "name")] public string Name { get; set; }
            [DataMember(Name = "browser_download_url")] public string Download { get; set; }
            [DataMember(Name = "digest")] public string Digest { get; set; }
            [DataMember(Name = "size")] public long Size { get; set; }
            [DataMember(Name = "state")] public string State { get; set; }
        }

        internal static UpdateOffer Parse(Stream body, Version installed)
        {
            var release = (Release)new DataContractJsonSerializer(typeof(Release)).ReadObject(body);
            if (release == null || release.Draft || release.Prerelease || !ParseVersion(release.Tag, out var version)
                || version.CompareTo(installed) <= 0) return null;
            var asset = release.Assets?.FirstOrDefault(item => item?.Name == AssetName && item.State == "uploaded");
            if (asset == null) return null;
            string url = ReleasePage + "/download/" + release.Tag + "/" + AssetName;
            if (!string.Equals(asset.Download, url, StringComparison.Ordinal) || asset.Size <= 0 || asset.Size > PackageLimit
                || !Regex.IsMatch(asset.Digest ?? "", @"\Asha256:[0-9a-f]{64}\z"))
                throw new InvalidDataException("GitHub 更新包的地址、大小或校验值无效。");
            return new UpdateOffer(version, new Uri(url), asset.Digest.Substring(7), asset.Size);
        }

        private static bool ParseVersion(string text, out Version version)
        {
            version = null;
            if (!Regex.IsMatch(text ?? "", @"\Av?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z"))
                return false;
            return Version.TryParse(text.TrimStart('v'), out version);
        }

        public static async Task<UpdateOffer> Latest()
        {
            var current = Assembly.GetExecutingAssembly().GetName().Version;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
            using var response = await Request(Endpoint, metadata: true, timeout.Token).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.NotFound) return null;
            response.EnsureSuccessStatusCode();
            using var content = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
            using var body = new MemoryStream();
            await CopyLimited(content, body, 1024 * 1024, timeout.Token).ConfigureAwait(false);
            body.Position = 0;
            return Parse(body, new Version(current.Major, current.Minor, current.Build));
        }

        private static async Task<HttpResponseMessage> Request(Uri url, bool metadata, CancellationToken token)
        {
            for (int redirects = 0; redirects < 6; redirects++)
            {
                if (url.Scheme != Uri.UriSchemeHttps || !url.IsDefaultPort || url.UserInfo.Length != 0 ||
                    !(url.Host == "api.github.com" || url.Host == "github.com" ||
                      url.Host == "release-assets.githubusercontent.com" || url.Host == "objects.githubusercontent.com"))
                    throw new InvalidDataException("GitHub 更新包的下载地址无效。");

                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.UserAgent.ParseAdd("Suixinjie-Updater");
                if (metadata)
                {
                    request.Headers.Accept.ParseAdd("application/vnd.github+json");
                    request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
                }
                var response = await Client.Value.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
                int code = (int)response.StatusCode;
                if (code < 300 || code >= 400) return response;
                using (response)
                {
                    if (response.Headers.Location == null) break;
                    url = new Uri(url, response.Headers.Location);
                }
            }
            throw new InvalidDataException("GitHub 更新包的下载跳转无效。");
        }

        private static async Task<long> CopyLimited(Stream input, Stream output, long limit, CancellationToken token)
        {
            var buffer = new byte[64 * 1024];
            long total = 0;
            int count;
            while ((count = await input.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) > 0)
            {
                total += count;
                if (total > limit) throw new InvalidDataException("更新包超过预期大小。");
                await output.WriteAsync(buffer, 0, count, token).ConfigureAwait(false);
            }
            return total;
        }

        public static async Task PrepareAndLaunch(UpdateOffer update, string installed, int parent)
        {
            if (!string.Equals(Path.GetFileName(installed), ExeName, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("请将应用保留为 Suixinjie.exe，或从 GitHub 手动更新。");
            string location = Path.GetDirectoryName(installed);
            string stage = Path.Combine(location, StagePrefix + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stage);
            try
            {
                string archive = Path.Combine(stage, "update.zip");
                using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
                using (var response = await Request(update.Download, metadata: false, timeout.Token).ConfigureAwait(false))
                {
                    response.EnsureSuccessStatusCode();
                    using var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
                    using var file = new FileStream(archive, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, true);
                    long length = await CopyLimited(input, file, update.Size, timeout.Token).ConfigureAwait(false);
                    if (length != update.Size) throw new InvalidDataException("更新包大小有误。");
                }
                VerifyArchive(archive, update.Size, update.Digest);
                ExtractPackage(archive, stage);
                string candidate = Path.Combine(stage, ExeName);
                VerifyCandidate(candidate, installed, update.Version);
                string helper = Path.Combine(stage, HelperName);
                File.Copy(installed, helper);
                if (File.Exists(installed + ".config")) File.Copy(installed + ".config", helper + ".config");
                using var launched = Process.Start(new ProcessStartInfo(helper,
                    "--apply-update " + parent + " " + update.Version + " " + Hash(candidate) + " " +
                    Hash(Path.Combine(stage, ConfigName))) { UseShellExecute = false });
                if (launched == null) throw new InvalidOperationException("无法启动更新程序。");
            }
            catch { TryClean(stage); throw; }
        }

        internal static void VerifyArchive(string archive, long bytes, string digest)
        {
            if (new FileInfo(archive).Length != bytes || Hash(archive) != digest)
                throw new InvalidDataException("更新包大小或 SHA-256 校验值有误。");
        }

        private static string Hash(string path)
        {
            using var file = File.OpenRead(path);
            using var sha = SHA256.Create();
            return BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
        }

        internal static void ExtractPackage(string archive, string stage)
        {
            using var file = File.OpenRead(archive);
            using var zip = new ZipArchive(file, ZipArchiveMode.Read);
            foreach (string name in new[] { ExeName, ConfigName })
            {
                var entries = zip.Entries.Where(entry => entry.FullName == name).ToArray();
                long limit = name == ExeName ? PackageLimit : 256 * 1024;
                if (entries.Length != 1 || entries[0].Length <= 0 || entries[0].Length > limit)
                    throw new InvalidDataException("更新包缺少应用文件。");
                using var input = entries[0].Open();
                using var output = new FileStream(Path.Combine(stage, name), FileMode.CreateNew);
                long length = CopyLimited(input, output, limit, CancellationToken.None).GetAwaiter().GetResult();
                if (length != entries[0].Length) throw new InvalidDataException("更新包中的应用文件不完整。");
            }
        }

        private static void VerifyCandidate(string candidate, string installed, Version version)
        {
            var assembly = AssemblyName.GetAssemblyName(candidate);
            var versionInFile = assembly.Version;
            var existingVersion = AssemblyName.GetAssemblyName(installed).Version;
            if (assembly.Name != "Suixinjie" || versionInFile == null ||
                !new Version(versionInFile.Major, versionInFile.Minor, versionInFile.Build).Equals(version) ||
                versionInFile.CompareTo(existingVersion) <= 0)
                throw new InvalidDataException("新版程序的应用标识或版本不匹配。");

            string signer = Signer(installed);
            if (signer != null && (!string.Equals(signer, Signer(candidate), StringComparison.Ordinal) || !Trusted(candidate)))
                throw new InvalidDataException("新版程序的签名与当前安装不匹配，请手动更新。");
        }

        private static string Signer(string binary)
        {
            try
            {
                using var certificate = X509Certificate.CreateFromSignedFile(binary);
                return certificate.GetKeyAlgorithm() + ":" + certificate.GetPublicKeyString();
            }
            catch (CryptographicException) when (!HasCertificateTable(binary)) { return null; }
        }

        private static bool HasCertificateTable(string binary)
        {
            using var file = File.OpenRead(binary);
            using var reader = new BinaryReader(file);
            file.Position = 0x3c;
            int pe = reader.ReadInt32();
            file.Position = pe + 24;
            ushort magic = reader.ReadUInt16();
            if (magic != 0x10b && magic != 0x20b) throw new InvalidDataException("无法识别更新程序的签名格式。");
            file.Position = pe + 24 + (magic == 0x10b ? 96 : 112) + 4 * 8;
            return reader.ReadUInt32() != 0 || reader.ReadUInt32() != 0;
        }

        private static bool Trusted(string binary)
        {
            var file = new TrustFile { Size = (uint)Marshal.SizeOf(typeof(TrustFile)), Path = binary };
            IntPtr native = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(TrustFile)));
            try
            {
                Marshal.StructureToPtr(file, native, false);
                var data = new TrustData
                {
                    Size = (uint)Marshal.SizeOf(typeof(TrustData)), Ui = 2, Choice = 1, File = native
                };
                var policy = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
                return WinVerifyTrust(new IntPtr(-1), ref policy, ref data) == 0;
            }
            finally
            {
                Marshal.DestroyStructure(native, typeof(TrustFile));
                Marshal.FreeHGlobal(native);
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct TrustFile
        {
            public uint Size;
            [MarshalAs(UnmanagedType.LPWStr)] public string Path;
            public IntPtr Handle, Subject;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TrustData
        {
            public uint Size;
            public IntPtr Callback, Sip;
            public uint Ui, Revocation, Choice;
            public IntPtr File;
            public uint StateAction;
            public IntPtr State, Url;
            public uint Flags, Context;
        }

        [DllImport("wintrust.dll", ExactSpelling = true)]
        private static extern int WinVerifyTrust(IntPtr parent, ref Guid action, ref TrustData data);

        public static bool RunHelper(string[] args, string helper, Action<string> reportError)
        {
            if (args.Length == 0 || args[0] != "--apply-update") return false;
            string stage = Path.GetDirectoryName(helper);
            if (args.Length != 5 || !IsStageName(Path.GetFileName(stage)) ||
                (File.GetAttributes(stage) & FileAttributes.ReparsePoint) != 0 ||
                !string.Equals(Path.GetFileName(helper), HelperName, StringComparison.OrdinalIgnoreCase) ||
                !int.TryParse(args[1], out int parent) || parent <= 0 || !ParseVersion(args[2], out var version) ||
                !Regex.IsMatch(args[3], @"\A[0-9a-f]{64}\z") || !Regex.IsMatch(args[4], @"\A[0-9a-f]{64}\z")) return true;

            string installed = Path.Combine(Path.GetDirectoryName(stage), ExeName);
            string candidate = Path.Combine(stage, ExeName);
            string backup = Path.Combine(stage, "previous.exe");
            string configBackup = Path.Combine(stage, "previous.config");
            string config = installed + ".config";
            bool installedNewConfig = false;
            try
            {
                try
                {
                    using var process = Process.GetProcessById(parent);
                    if (!process.WaitForExit(30000)) throw new InvalidOperationException("随心截还在运行，无法替换文件。");
                }
                catch (ArgumentException) { }
                string newConfig = Path.Combine(stage, ConfigName);
                if (Hash(candidate) != args[3] || Hash(newConfig) != args[4])
                    throw new InvalidDataException("待安装文件的校验值已经改变。");
                VerifyCandidate(candidate, installed, version);
                File.Replace(candidate, installed, backup);
                if (File.Exists(config)) File.Replace(newConfig, config, configBackup);
                else { File.Move(newConfig, config); installedNewConfig = true; }
                Restart(installed, stage);
            }
            catch (Exception error)
            {
                try
                {
                    if (File.Exists(configBackup)) File.Replace(configBackup, config, null);
                    else if (installedNewConfig) File.Delete(config);
                    if (File.Exists(backup)) File.Replace(backup, installed, null);
                    Restart(installed, stage);
                }
                catch { /* Keep the staging directory if the previous files could not be restored. */ }
                reportError("无法安装更新。" + error.Message);
            }
            return true;
        }

        private static void Restart(string installed, string stage)
        {
            using var process = Process.Start(new ProcessStartInfo(installed,
                "--finish-update " + Path.GetFileName(stage)) { UseShellExecute = false });
            if (process == null) throw new InvalidOperationException("无法重新启动随心截。");
        }

        public static void ScheduleCleanup(string[] args, string executable)
        {
            if (args.Length != 2 || args[0] != "--finish-update" || !IsStageName(args[1])) return;
            string stage = Path.Combine(Path.GetDirectoryName(executable), args[1]);
            _ = Task.Run(async () =>
            {
                for (int retry = 0; retry < 20 && Directory.Exists(stage); retry++)
                {
                    TryClean(stage);
                    await Task.Delay(500).ConfigureAwait(false);
                }
            });
        }

        private static bool IsStageName(string name) => name != null && name.StartsWith(StagePrefix, StringComparison.Ordinal)
            && Guid.TryParseExact(name.Substring(StagePrefix.Length), "N", out _);

        private static void TryClean(string stage)
        {
            try
            {
                if (Directory.Exists(stage) && (File.GetAttributes(stage) & FileAttributes.ReparsePoint) == 0)
                {
                    foreach (string file in new[] { HelperName, HelperName + ".config", ExeName, ConfigName,
                                                    "update.zip", "previous.exe", "previous.config" })
                        File.Delete(Path.Combine(stage, file));
                    Directory.Delete(stage, false);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
