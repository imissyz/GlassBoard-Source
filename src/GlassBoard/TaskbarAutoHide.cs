using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace GlassBoard;

public static class TaskbarAutoHide
{
	private struct RECT
	{
		public int Left;

		public int Top;

		public int Right;

		public int Bottom;
	}

	private struct APPBARDATA
	{
		public uint Size;

		public IntPtr Window;

		public uint Message;

		public uint Edge;

		public RECT Rect;

		public IntPtr Param;
	}

	private static string Journal => Path.Combine(Store.Folder, "taskbar-autohide.json");

	private static readonly TaskbarStateAccess Access = new TaskbarStateAccess(ReadNative, WriteNative);

	public static bool Enabled => (ReadState() & 1) != 0;

	public static async Task<bool> ReadEnabledAsync() => ((await Access.ReadAsync().ConfigureAwait(false)) & 1u) != 0;

	public static async Task<bool> SetAsync(bool? enabled) => ((await Access.SetAutoHideAsync(enabled).ConfigureAwait(false)) & 1u) != 0;

	internal static uint ReadState() => Access.ReadAsync().GetAwaiter().GetResult();

	internal static void WriteState(uint state) => Access.WriteAsync(state).GetAwaiter().GetResult();

	[DllImport("shell32.dll")]
	private static extern UIntPtr SHAppBarMessage(uint message, ref APPBARDATA data);

	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	private static extern IntPtr FindWindow(string cls, string name);

	private static APPBARDATA Data()
	{
		APPBARDATA result = new APPBARDATA
		{
			Size = (uint)Marshal.SizeOf(typeof(APPBARDATA)),
			Window = FindWindow("Shell_TrayWnd", null)
		};
		if (result.Window == IntPtr.Zero)
		{
			throw new InvalidOperationException("未找到 Windows 任务栏");
		}
		return result;
	}

	private static uint ReadNative()
	{
		APPBARDATA data = Data();
		return (uint)SHAppBarMessage(4u, ref data).ToUInt64();
	}

	private static void WriteNative(uint state)
	{
		APPBARDATA data = Data();
		data.Param = new IntPtr(state);
		SHAppBarMessage(10u, ref data);
	}

	public static void Set(bool enabled)
	{
		SetAsync(enabled).GetAwaiter().GetResult();
	}

	public static void RetireLegacyJournal()
	{
		// Automatic hiding is a Windows setting. App startup/exit must not undo
		// a subsequent change made in Windows Settings using an old session journal.
		if (File.Exists(Journal))
		{
			File.Move(Journal, Journal + ".legacy-" + DateTime.UtcNow.Ticks);
		}
	}

	public static void ShowAndClear()
	{
		Set(false);
		RetireLegacyJournal();
	}
}
