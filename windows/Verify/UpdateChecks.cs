using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using Suixinjie;

internal static class UpdateChecks
{
    internal static void Run()
    {
        string tag = "v0.2.0";
        string hash = new string('a', 64);
        string url = GitHubUpdater.ReleasePage + "/download/" + tag + "/" + GitHubUpdater.AssetName;
        UpdateOffer Offer(Version version, bool prerelease = false, string source = null)
        {
            string body = "{\"tag_name\":\"" + tag + "\",\"draft\":false,\"prerelease\":" +
                          (prerelease ? "true" : "false") + ",\"assets\":[{\"name\":\"" + GitHubUpdater.AssetName +
                          "\",\"browser_download_url\":\"" + (source ?? url) + "\",\"digest\":\"sha256:" + hash +
                          "\",\"size\":3,\"state\":\"uploaded\"}]}";
            using var json = new MemoryStream(Encoding.UTF8.GetBytes(body));
            return GitHubUpdater.Parse(json, version);
        }
        var installed = new Version(0, 1, 10);
        var candidate = new Version(0, 2, 0);
        Check(Offer(installed)?.Version.Equals(candidate) == true, "select newer stable release");
        Check(Offer(candidate) == null && Offer(installed, prerelease: true) == null, "ignore current and prerelease versions");
        Reject(() => Offer(installed, source: "https://example.com/package.zip"), "reject non-GitHub asset");

        string stage = Path.Combine(Path.GetTempPath(), "suixinjie-update-verify-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            string content = Path.Combine(stage, "check.txt");
            File.WriteAllBytes(content, Encoding.ASCII.GetBytes("abc"));
            GitHubUpdater.VerifyArchive(content, 3, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
            Reject(() => GitHubUpdater.VerifyArchive(content, 3, hash), "reject changed bytes");
            string archive = Path.Combine(stage, "update.zip");
            using (var file = File.Create(archive))
            using (var zip = new ZipArchive(file, ZipArchiveMode.Create))
            {
                foreach (string name in new[] { "Suixinjie.exe", "Suixinjie.exe.config", "nested/other.txt" })
                {
                    using var entry = zip.CreateEntry(name).Open();
                    entry.WriteByte(65);
                }
            }
            GitHubUpdater.ExtractPackage(archive, stage);
            Check(File.Exists(Path.Combine(stage, "Suixinjie.exe")) &&
                  File.Exists(Path.Combine(stage, "Suixinjie.exe.config")) &&
                  !Directory.Exists(Path.Combine(stage, "nested")), "extract only approved update paths");
        }
        finally { Directory.Delete(stage, true); }
        Console.WriteLine("PASS: update selection, origin, checksum and package extraction");
    }

    private static void Reject(Action action, string label)
    {
        try { action(); }
        catch (InvalidDataException) { return; }
        throw new InvalidOperationException(label);
    }

    private static void Check(bool condition, string label)
    {
        if (!condition) throw new InvalidOperationException(label);
    }
}
