using System;
using System.Threading;
using System.Threading.Tasks;

namespace GlassBoard;

// All AppBar reads and writes share this queue, including temporary complete hiding.
// A timed-out native call remains in flight: never spawn more blocked shell calls.
internal sealed class TaskbarStateAccess
{
	private readonly Func<uint> read;
	private readonly Action<uint> write;
	private readonly int timeout;
	private readonly SemaphoreSlim gate = new SemaphoreSlim(1, 1);
	private Task<uint> inFlight;

	internal TaskbarStateAccess(Func<uint> read, Action<uint> write, int timeout = 1200)
	{
		this.read = read;
		this.write = write;
		this.timeout = timeout;
	}

	internal Task<uint> ReadAsync() => ExecuteAsync(read);

	internal Task<uint> SetAutoHideAsync(bool? enabled) => ExecuteAsync(() =>
	{
		uint current = read();
		bool target = enabled ?? ((current & 1u) == 0);
		uint desired = target ? current | 1u : current & ~1u;
		if (desired != current)
		{
			write(desired);
		}
		return Confirm(desired);
	});

	internal Task<uint> WriteAsync(uint desired) => ExecuteAsync(() =>
	{
		if (read() != desired)
		{
			write(desired);
		}
		return Confirm(desired);
	});

	private uint Confirm(uint desired)
	{
		uint actual = read();
		if ((actual & 3u) != (desired & 3u))
		{
			throw new InvalidOperationException("Windows 未确认任务栏设置，未保存此次切换。请稍后重试。");
		}
		return actual;
	}

	private async Task<uint> ExecuteAsync(Func<uint> operation)
	{
		if (!await gate.WaitAsync(timeout).ConfigureAwait(false))
		{
			throw new TimeoutException("任务栏正在处理其他请求，请稍后重试。");
		}
		try
		{
			if (inFlight != null && !inFlight.IsCompleted)
			{
				throw new TimeoutException("Windows 任务栏尚未响应上一次请求，暂不发送新的切换。");
			}
			inFlight = Task.Run(operation);
			// Observe faults even if the shell finishes after our timeout.
			_ = inFlight.ContinueWith(t => { var ignored = t.Exception; },
				TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
			if (await Task.WhenAny(inFlight, Task.Delay(timeout)).ConfigureAwait(false) != inFlight)
			{
				throw new TimeoutException("Windows 任务栏响应超时，状态尚未确认，未保存此次切换。");
			}
			return await inFlight.ConfigureAwait(false);
		}
		finally
		{
			gate.Release();
		}
	}
}
