using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using GlassBoard;

static class Program
{
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static async Task Expect<T>(Task task) where T : Exception
    {
        try { await task; } catch (T) { return; }
        throw new Exception("Expected " + typeof(T).Name);
    }
    static async Task Main()
    {
        uint state = 10;
        var writes = new List<uint>();
        var access = new TaskbarStateAccess(() => state, value => { Thread.Sleep(20); writes.Add(value); state = value; });
        var first = access.SetAutoHideAsync(true);
        var second = access.SetAutoHideAsync(false);
        var third = access.SetAutoHideAsync(true);
        await Task.WhenAll(first, second, third);
        Check(writes.SequenceEqual(new uint[] { 11, 10, 11 }) && state == 11, "Rapid toggles lost ordering/flags");
        Console.WriteLine("PASS: rapid toggles serialize and preserve unrelated state bits");
        await access.SetAutoHideAsync(null);
        Check(state == 10, "Atomic toggle used stale state");
        Console.WriteLine("PASS: toggle without an explicit target reads the actual state atomically");

        var rejected = new TaskbarStateAccess(() => 2, value => { });
        await Expect<InvalidOperationException>(rejected.SetAutoHideAsync(true));
        var missing = new TaskbarStateAccess(() => throw new InvalidOperationException("No taskbar"), value => { });
        await Expect<InvalidOperationException>(missing.ReadAsync());
        Console.WriteLine("PASS: failed writes and missing shell are errors, not false success/off");

        using var release = new ManualResetEventSlim(false);
        int reads = 0, blockedWrites = 0;
        var blocked = new TaskbarStateAccess(() => { Interlocked.Increment(ref reads); release.Wait(); return 2; }, value => Interlocked.Increment(ref blockedWrites), 100);
        await Expect<TimeoutException>(blocked.ReadAsync());
        await Expect<TimeoutException>(blocked.ReadAsync());
        await Expect<TimeoutException>(blocked.SetAutoHideAsync(false));
        Check(reads == 1 && blockedWrites == 0, "Hung calls accumulated or an unknown state triggered a write");
        release.Set();
        await Task.Delay(30);
        Check(await blocked.ReadAsync() == 2, "Did not recover after shell became responsive");
        Console.WriteLine("PASS: timeout remains unknown; repeated requests spawn no additional blocked native calls; recovery works");

        state = 2;
        writes.Clear();
        await Task.WhenAll(access.WriteAsync(3), access.SetAutoHideAsync(false));
        Check(state == 2 && writes.SequenceEqual(new uint[] { 3, 2 }), "Temporary hide and auto-hide bypassed the shared queue");
        Console.WriteLine("PASS: temporary full-hide state and automatic hiding share the same ordered transport");
    }
}
