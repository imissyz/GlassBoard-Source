param([Parameter(Mandatory=$true)][string]$AssemblyPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
$assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath))
$flags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
function Invoke-Private($target, [string]$name, [object[]]$arguments = @()) {
    for ($argIndex = 0; $argIndex -lt $arguments.Length; $argIndex++) {
        if ($arguments[$argIndex] -is [System.Management.Automation.PSObject]) { $arguments[$argIndex] = $arguments[$argIndex].PSObject.BaseObject }
    }
    $target.GetType().GetMethod($name, $flags).Invoke($target, $arguments)
}
function Pump-Dispatcher {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $callback = [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null }
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, $callback, $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Assert($condition, [string]$message) { if (!$condition) { throw $message } }
$controllerType = $assembly.GetType('GlassBoard.Controller')
$ctor = $controllerType.GetConstructor($flags, $null, [type[]]@([bool]), $null)
$staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
$folderField = $assembly.GetType('GlassBoard.Store').GetField('Folder', $staticFlags)
$oldFolder = $folderField.GetValue($null)
$testFolder = Join-Path ([IO.Path]::GetTempPath()) ('GlassBoard-popup-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testFolder -Force | Out-Null
$folderField.SetValue($null, $testFolder)
$controller = $ctor.Invoke([object[]]@($false))
try {
    $controller.Prefs.Normalize()
    foreach ($key in $controller.Prefs.Hotkeys) { $key.Enabled = $false }
    $controller.Prefs.Dock.Material.LiveBlur = $false
    $controller.Dock.Left = 600
    $controller.Dock.Top = 650
    $controller.Dock.Width = 400
    $owner = New-Object System.Windows.Controls.Button
    $popupField = $controller.Dock.GetType().GetField('runningListPopup', $flags)
    $popup = Invoke-Private $controller.Dock 'OpenRunningList' @($owner)
    $popupField.SetValue($controller.Dock, $popup)
    $shell = $popup.Child
    $before = @($popup.HorizontalOffset, $popup.VerticalOffset, $shell.Width, $shell.Height)
    Pump-Dispatcher
    $shell.UpdateLayout()
    Assert $popup.IsOpen 'Running list closed unexpectedly during icon loading'
    Assert ([Math]::Abs($before[0] - $popup.HorizontalOffset) -lt 0.1 -and [Math]::Abs($before[1] - $popup.VerticalOffset) -lt 0.1) 'Running list moved after opening'
    Assert (![double]::IsNaN($shell.Width) -and ![double]::IsNaN($shell.Height)) 'Running list has no stable initial bounds'
    Assert ([Math]::Abs($shell.ActualWidth - $before[2]) -lt 0.1 -and [Math]::Abs($shell.ActualHeight - $before[3]) -lt 0.1) 'Measured and displayed bounds differ'
    $rows = $shell.Child.Content.Children
    $iconCount = 0
    foreach ($row in $rows) {
        if ($row -is [System.Windows.Controls.Border]) {
            $icon = $row.Child.Children[0]
            Assert ($icon -is [System.Windows.Controls.Image] -and $icon.Width -eq 18 -and $icon.Height -eq 18) 'Missing fixed icon slot'
            $iconCount++
        }
    }
    Write-Output ('PASS: deferred icons preserve popup bounds and offsets; rows={0}; size={1}x{2}' -f $iconCount,$shell.ActualWidth,$shell.ActualHeight)
    for ($i=0; $i -lt 3; $i++) {
        $controller.ToggleControlCenter()
        Assert (!$popup.IsOpen) 'Control center did not dismiss running list'
        Assert ($null -ne $controller.ControlCenter -and $controller.ControlCenter.IsVisible) 'Control center did not open'
        $oldCenter = $controller.ControlCenter
        if ($i -eq 0) {
            $section = $oldCenter.GetType().GetField('brightnessSection', $flags).GetValue($oldCenter)
            $slider = $oldCenter.GetType().GetField('brightnessSlider', $flags).GetValue($oldCenter)
            $value = $oldCenter.GetType().GetField('brightnessValue', $flags).GetValue($oldCenter)
            Invoke-Private $oldCenter 'ApplyBrightnessState' @($null, $true)
            Assert ($section.Visibility -eq 'Visible' -and !$slider.IsEnabled -and $value.Text -eq '--') 'Unsupported brightness disappeared or remained interactive'
            Invoke-Private $oldCenter 'ApplyBrightnessState' @([int]42, $true)
            Assert ($slider.IsEnabled -and $slider.Value -eq 42 -and $value.Text -eq '42') 'Brightness did not recover when support became available'
            Invoke-Private $oldCenter 'ApplyBrightnessState' @($null, $false)
            Assert ($section.Visibility -eq 'Collapsed') 'Explicit brightness visibility preference was ignored'
            Write-Output 'PASS: unsupported brightness stays visible; recovery and explicit hiding work'
        }
        $popup = Invoke-Private $controller.Dock 'OpenRunningList' @($owner)
        $popupField.SetValue($controller.Dock, $popup)
        Assert (!$oldCenter.IsVisible -and $null -eq $controller.ControlCenter) 'Running list did not close control center'
        Assert $popup.IsOpen 'Running list did not open after control center'
        Pump-Dispatcher
    }
    Write-Output 'PASS: both panel switch directions, repeated three times'
    $controller.Dock.CloseRunningList()
    $controller.Dock.CloseRunningList()
    Assert (!$popup.IsOpen) 'Repeated dismissal failed'
    Write-Output 'PASS: repeated dismissal is safe'
}
finally {
    $controller.ShuttingDown = $true
    if ($null -ne $controller.ControlCenter) { $controller.ControlCenter.Close() }
    $currentPopup = $controller.Dock.GetType().GetField('runningListPopup', $flags).GetValue($controller.Dock)
    if ($null -ne $currentPopup) { $currentPopup.IsOpen = $false }
    $controller.Dock.ReleaseHotkey()
    $controller.Board.Close()
    $controller.Dock.Close()
    $folderField.SetValue($null, $oldFolder)
}
