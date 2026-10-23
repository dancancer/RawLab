# 每个检查独占一个进程；UI Dispatcher 卡住也不能阻塞外部截止时间。
function Invoke-CheckProcess {
    param([string]$Name,[string]$Executable,[string[]]$Arguments,[string]$Directory,
          [string]$Log,[ValidateRange(1,86400)][int]$TimeoutSeconds,[switch]$CaptureOutput)
    function Quote-Argument([string]$Value) {
        '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
    }
    $command=(Get-Command $Executable -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$command
    $info.Arguments=(@($Arguments | ForEach-Object {Quote-Argument $_}) -join ' ')
    if([IO.Path]::GetExtension($command) -in @('.cmd','.bat')) {
        $info.FileName=$env:ComSpec
        $info.Arguments='/d /s /c "'+(Quote-Argument $command)+' '+$info.Arguments+'"'
    }
    $info.WorkingDirectory=$Directory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    $writer=New-Object IO.StreamWriter($Log,$false,(New-Object Text.UTF8Encoding($false)))
    $writer.AutoFlush=$true
    $watch=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false;$started=$false
    $stdout=New-Object 'Collections.Generic.List[string]'
    function Record([string]$Line) {
        $text='[{0} {1:F1}s] {2}' -f $Name,$watch.Elapsed.TotalSeconds,$Line
        $writer.WriteLine($text);Write-Host $text
    }
    try {
        $started=$process.Start()
        if(!$started){throw "Cannot start $Name"}
        Record "START pid=$($process.Id) timeout=${TimeoutSeconds}s"
        $readers=@($process.StandardOutput,$process.StandardError)
        $pending=@($readers[0].ReadLineAsync(),$readers[1].ReadLineAsync())
        $exitedAt=$null
        while($true) {
            # 每轮限量读，持续输出的子进程也不能饿死超时检查。
            for($i=0;$i -lt 2;$i++) {
                for($lineCount=0;$lineCount -lt 100 -and $null -ne $pending[$i] -and $pending[$i].IsCompleted;$lineCount++) {
                    $line=$pending[$i].GetAwaiter().GetResult()
                    if($null -eq $line){$pending[$i]=$null;break}
                    if($CaptureOutput -and $i -eq 0){$stdout.Add($line)}
                    Record $line;$pending[$i]=$readers[$i].ReadLineAsync()
                }
            }
            if(!$process.HasExited -and $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut=$true;Record "TIMEOUT after ${TimeoutSeconds}s; terminating owned process tree pid=$($process.Id)"
                & taskkill.exe /PID $process.Id /T /F 2>&1 | ForEach-Object {Record "$_"}
                if(!$process.WaitForExit(5000)){throw "Cannot stop timed-out check $Name (pid=$($process.Id))"}
            }
            if($process.HasExited) {
                if($null -eq $exitedAt){$exitedAt=$watch.Elapsed.TotalSeconds}
                if(($null -eq $pending[0] -and $null -eq $pending[1]) -or $watch.Elapsed.TotalSeconds-$exitedAt -gt 2){break}
            }
            Start-Sleep -Milliseconds 50
        }
        $code=if($timedOut){124}else{$process.ExitCode}
        Record "END exit=$code"
        return [pscustomobject]@{exitCode=$code;timedOut=$timedOut;durationSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2);pid=$process.Id;stdout=$stdout.ToArray()}
    }
    finally {
        if($started -and !$process.HasExited){& taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null}
        $writer.Dispose();$process.Dispose()
    }
}
