using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Reflection.Emit;
using System.Security.Cryptography;
using System.Threading;
using Suixinjie;

internal static class UpdateInstallCheck
{
    private const string AppName = "Suixinjie.exe";

    internal static void Run()
    {
        string root = Path.Combine(Path.GetTempPath(), "suixinjie-install-verify-" + Guid.NewGuid().ToString("N"));
        string stage = Path.Combine(root, ".suixinjie-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            var oldVersion = new Version(0, 1, 0, 0);
            var newVersion = new Version(0, 2, 9, 0);
            string marker = Path.Combine(root, "restarted.txt");
            MakeFixture(root, oldVersion, marker: null);
            MakeFixture(stage, newVersion, marker);
            string old = Path.Combine(root, AppName);
            string candidate = Path.Combine(stage, AppName);
            string config = old + ".config";
            string nextConfig = candidate + ".config";
            File.WriteAllText(config, "<configuration><!-- previous --></configuration>");
            File.WriteAllText(nextConfig, "<configuration><!-- current --></configuration>");
            string helper = Path.Combine(stage, "apply.exe");
            File.Copy(typeof(GitHubUpdater).Assembly.Location, helper);

            using var parent = Process.Start(new ProcessStartInfo(old) { UseShellExecute = false });
            using var apply = Process.Start(new ProcessStartInfo(helper, "--apply-update " + parent.Id + " " +
                newVersion.ToString(3) + " " + Digest(candidate) + " " + Digest(nextConfig)) { UseShellExecute = false });
            if (!apply.WaitForExit(15000))
            {
                apply.Kill();
                apply.WaitForExit();
                throw new InvalidOperationException("The Windows update helper did not finish.");
            }
            for (int retry = 0; retry < 40 && !File.Exists(marker); retry++) Thread.Sleep(100);
            if (!File.Exists(marker) || AssemblyName.GetAssemblyName(old).Version != newVersion ||
                !File.ReadAllText(config).Contains("current") ||
                AssemblyName.GetAssemblyName(Path.Combine(stage, "previous.exe")).Version != oldVersion)
                throw new InvalidOperationException("The Windows update did not replace the executable, retain a backup, and restart.");
        }
        finally
        {
            for (int retry = 0; retry < 10 && Directory.Exists(root); retry++)
            {
                try { Directory.Delete(root, true); }
                catch (IOException) when (retry < 9) { Thread.Sleep(100); }
            }
        }
        Console.WriteLine("PASS: Windows update helper replaced an isolated install and restarted it");
    }

    private static string Digest(string filename)
    {
        using var file = File.OpenRead(filename);
        using var hash = SHA256.Create();
        return BitConverter.ToString(hash.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
    }

    private static void MakeFixture(string directory, Version version, string marker)
    {
        var name = new AssemblyName("Suixinjie") { Version = version };
        var assembly = AppDomain.CurrentDomain.DefineDynamicAssembly(name, AssemblyBuilderAccess.Save, directory);
        var module = assembly.DefineDynamicModule("Program", AppName);
        var type = module.DefineType("Program", TypeAttributes.Public);
        var main = type.DefineMethod("Main", MethodAttributes.Public | MethodAttributes.Static, typeof(void), Type.EmptyTypes);
        var body = main.GetILGenerator();
        if (marker == null)
        {
            body.Emit(OpCodes.Ldc_I4, 700);
            body.Emit(OpCodes.Call, typeof(Thread).GetMethod(nameof(Thread.Sleep), new[] { typeof(int) }));
        }
        else
        {
            body.Emit(OpCodes.Ldstr, marker);
            body.Emit(OpCodes.Ldstr, "restarted");
            body.Emit(OpCodes.Call, typeof(File).GetMethod(nameof(File.WriteAllText), new[] { typeof(string), typeof(string) }));
        }
        body.Emit(OpCodes.Ret);
        type.CreateType();
        assembly.SetEntryPoint(main, PEFileKinds.WindowApplication);
        assembly.Save(AppName);
    }
}
