param([Parameter(Mandatory=$true)][string]$AssemblyPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class TaskbarTestShell {
 public static uint State = 2;
 public static int Writes;
 public static bool RejectWrites, FailReads;
 public static uint Read() { if(FailReads) throw new InvalidOperationException("Simulated unavailable shell"); return State; }
 public static void Write(uint state) { Interlocked.Increment(ref Writes); if(!RejectWrites) State=state; }
 public static readonly Func<uint> Reader=Read;
 public static readonly Action<uint> Writer=Write;
}
'@
$assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath))
$flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
$staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
function Invoke-Private($target, [string]$name, [object[]]$arguments = @()) {
    for ($argIndex=0; $argIndex -lt $arguments.Length; $argIndex++) {
        if ($arguments[$argIndex] -is [System.Management.Automation.PSObject]) { $arguments[$argIndex]=$arguments[$argIndex].PSObject.BaseObject }
    }
    $target.GetType().GetMethod($name,$flags).Invoke($target,$arguments)
}
function Pump-Dispatcher {
    $frame=New-Object System.Windows.Threading.DispatcherFrame
    $callback=[System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue=$false; return $null }
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle,$callback,$frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Wait-Task($task) {
    $limit=[DateTime]::UtcNow.AddSeconds(5)
    while (!$task.IsCompleted) { Pump-Dispatcher; if ([DateTime]::UtcNow -gt $limit) { throw 'Test task did not complete' } }
    [void]$task.GetAwaiter().GetResult()
}
function Assert($condition,[string]$message) { if(!$condition) {throw $message} }
$facade=$assembly.GetType('GlassBoard.TaskbarAutoHide')
$accessField=$facade.GetField('Access',$staticFlags)
$originalAccess=$accessField.GetValue($null)
$accessType=$assembly.GetType('GlassBoard.TaskbarStateAccess')
$accessCtor=$accessType.GetConstructors($flags)[0]
$fakeAccess=$accessCtor.Invoke([object[]]@([TaskbarTestShell]::Reader,[TaskbarTestShell]::Writer,1200))
$storeType=$assembly.GetType('GlassBoard.Store')
$folderField=$storeType.GetField('Folder',$staticFlags)
$oldFolder=$folderField.GetValue($null)
$testFolder=Join-Path ([IO.Path]::GetTempPath()) ('GlassBoard-taskbar-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testFolder -Force | Out-Null
$folderField.SetValue($null,$testFolder)
$accessField.SetValue($null,$fakeAccess)
$controller=$null
try {
    $controllerType=$assembly.GetType('GlassBoard.Controller')
    $controller=$controllerType.GetConstructor($flags,$null,[type[]]@([bool]),$null).Invoke([object[]]@($false))
    $controller.Prefs.Normalize()
    foreach($key in $controller.Prefs.Hotkeys) { $key.Enabled=$false }
    $controller.Prefs.AutoHideTaskbar=$true
    Invoke-Private $controller 'ApplyShellPreferences'
    Wait-Task (Invoke-Private $controller 'SyncTaskbarPreferenceAsync')
    Pump-Dispatcher
    Assert (!$controller.Prefs.AutoHideTaskbar -and [TaskbarTestShell]::Writes -eq 0) 'Startup reapplied stale enabled preference'
    Write-Output 'PASS: startup adopts Windows off despite a saved enabled preference; no native writes'

    [TaskbarTestShell]::State=3
    Wait-Task (Invoke-Private $controller 'SyncTaskbarPreferenceAsync')
    Assert $controller.Prefs.AutoHideTaskbar 'External Windows enable was not adopted'
    [TaskbarTestShell]::State=2
    Wait-Task (Invoke-Private $controller 'SyncTaskbarPreferenceAsync')
    Assert (!$controller.Prefs.AutoHideTaskbar -and [TaskbarTestShell]::Writes -eq 0) 'External disable triggered a write-back'
    Write-Output 'PASS: external on/off changes update preferences without writing back'

    Wait-Task (Invoke-Private $controller 'ChangeTaskbarAutoHideAsync' @($true))
    Assert ($controller.Prefs.AutoHideTaskbar -and [TaskbarTestShell]::State -eq 3) 'Confirmed enable did not update preference'
    Wait-Task (Invoke-Private $controller 'ChangeTaskbarAutoHideAsync' @($false))
    Assert (!$controller.Prefs.AutoHideTaskbar -and [TaskbarTestShell]::State -eq 2) 'Confirmed disable did not update preference'
    [TaskbarTestShell]::RejectWrites=$true
    $failed=$false
    try { Wait-Task (Invoke-Private $controller 'ChangeTaskbarAutoHideAsync' @($true)) } catch { $failed=$true }
    Assert ($failed -and !$controller.Prefs.AutoHideTaskbar) 'Rejected write was saved as success'
    [TaskbarTestShell]::RejectWrites=$false
    Write-Output 'PASS: preferences change only after shell read-back confirms the requested state'

    $controller.Prefs.AutoHideTaskbar=$true
    [TaskbarTestShell]::FailReads=$true
    Wait-Task (Invoke-Private $controller 'SyncTaskbarPreferenceAsync')
    $actualField=$controllerType.GetField('actualTaskbarAutoHide',$flags)
    Assert ($controller.Prefs.AutoHideTaskbar -and $null -eq $actualField.GetValue($controller)) 'Unavailable shell was treated as off'
    [TaskbarTestShell]::FailReads=$false
    Write-Output 'PASS: unavailable shell leaves the saved preference intact and exposes unknown UI state'

    [TaskbarTestShell]::State=3
    $oldWrites=[TaskbarTestShell]::Writes
    [IO.File]::WriteAllText((Join-Path $testFolder 'taskbar-autohide.json'),'0')
    $facade.GetMethod('RetireLegacyJournal',$staticFlags).Invoke($null,@())
    Assert ([TaskbarTestShell]::State -eq 3 -and [TaskbarTestShell]::Writes -eq $oldWrites -and !(Test-Path (Join-Path $testFolder 'taskbar-autohide.json'))) 'Legacy journal undid a current Windows setting'
    Write-Output 'PASS: legacy session journal is archived without changing the taskbar'
}
finally {
    if($null -ne $controller) {
        $controller.ShuttingDown=$true
        $controller.Dock.ReleaseHotkey()
        $controller.Board.Close()
        $controller.Dock.Close()
    }
    $accessField.SetValue($null,$originalAccess)
    $folderField.SetValue($null,$oldFolder)
}
