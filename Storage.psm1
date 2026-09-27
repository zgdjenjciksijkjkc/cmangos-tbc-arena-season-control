Set-StrictMode -Version 2
function Initialize-ArenaProcessEnvironment {
    # Normalize duplicate Path/PATH spellings in this process only. Preserve
    # the effective Windows value; never change user/machine environment.
    $variables=[Environment]::GetEnvironmentVariables('Process')
    foreach($group in @($variables.Keys | Group-Object {$_.ToLowerInvariant()} | Where-Object {$_.Count -gt 1})){
        $name=[string]$group.Group[0]
        $value=[Environment]::GetEnvironmentVariable($name,'Process')
        foreach($key in $group.Group){[Environment]::SetEnvironmentVariable([string]$key,$null,'Process')}
        [Environment]::SetEnvironmentVariable($name,$value,'Process')
    }
}
function Read-ArenaConnection([string]$Config,[string]$Key){
    $raw=[IO.File]::ReadAllText($Config)
    $m=[regex]::Matches($raw,'(?m)^\s*'+[regex]::Escape($Key)+'\s*=\s*"([^"]+)"')
    if($m.Count -ne 1){throw "配置项缺失或重复：$Key"}
    $v=$m[0].Groups[1].Value.Split(';')
    if($v.Count -ne 5 -or $v[0] -notin @('127.0.0.1','localhost') -or $v[1] -notmatch '^\d+$' -or $v[4] -notmatch '^tbc[a-z]+$'){throw '仅支持已确认的本机 TBC 数据库。'}
    [pscustomobject]@{Host='127.0.0.1';Port=[int]$v[1];User=$v[2];Password=$v[3];Database=$v[4]}
}
function Invoke-ArenaSql {
    param($Connection,[string]$Tools,[string]$Sql,[string]$File)
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=Join-Path $Tools 'mysql.exe'
    if($Connection.User -notmatch '^[a-zA-Z0-9_]+$' -or $Connection.Database -notmatch '^(tbc[a-z]+|mysql)$'){throw '数据库标识不受支持。'}
    $si.Arguments="--no-defaults --protocol=TCP --host=127.0.0.1 --port=$($Connection.Port) --user=$($Connection.User) --database=$($Connection.Database) --batch --raw --default-character-set=utf8"
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $si.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $si.EnvironmentVariables['MYSQL_PWD']=$Connection.Password
    $p=[Diagnostics.Process]::Start($si);$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync()
    # Windows PowerShell 5.1/.NET Framework lacks StandardInputEncoding.
    # Write UTF-8 explicitly to the redirected byte stream instead.
    $inputWriter=New-Object IO.StreamWriter($p.StandardInput.BaseStream,(New-Object Text.UTF8Encoding($false)))
    try{
        if($File){
            $reader=New-Object IO.StreamReader($File,[Text.Encoding]::UTF8)
            try{$buffer=New-Object char[] 65536;while(($n=$reader.Read($buffer,0,$buffer.Length)) -gt 0){$inputWriter.Write($buffer,0,$n)}}finally{$reader.Dispose()}
        }else{$inputWriter.WriteLine($Sql)}
        $inputWriter.Close();$p.WaitForExit()
        $output=$o.GetAwaiter().GetResult();$errorText=$e.GetAwaiter().GetResult()
        if($p.ExitCode -ne 0){throw "SQL 执行失败：$errorText"}
        return $output.TrimEnd("`r","`n")
    }finally{if(-not $p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}
}
function Read-ArenaRows {
    param($Connection,[string]$Tools,[string]$Sql)
    $text=Invoke-ArenaSql $Connection $Tools $Sql
    if($text){@($text | ConvertFrom-Csv -Delimiter "`t")}
}
function Save-ArenaDump {
    param($Connection,[string]$Tools,[string]$Path,[string]$Table,[string]$Where='1=1')
    $old=$env:MYSQL_PWD
    try{
        $env:MYSQL_PWD=$Connection.Password
        $args=@('--no-defaults','--protocol=TCP','--host=127.0.0.1',"--port=$($Connection.Port)","--user=$($Connection.User)",'--default-character-set=utf8','--skip-comments','--skip-triggers','--skip-lock-tables','--skip-add-locks','--skip-disable-keys','--set-gtid-purged=OFF','--order-by-primary',"--result-file=$Path")
        if($Table){$args+=@('--no-create-info','--skip-extended-insert',"--where=$Where",$Connection.Database,$Table)}else{$args+=@('--single-transaction',$Connection.Database)}
        $errorText=@(& (Join-Path $Tools 'mysqldump.exe') @args 2>&1)
        if($LASTEXITCODE -ne 0){throw "备份失败：$($errorText -join ' ')"}
    }finally{$env:MYSQL_PWD=$old}
}
function Get-ArenaHash([string]$Text){
    $h=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','')}finally{$h.Dispose()}
}
function Write-ArenaJson([string]$Path,$Value){
    $tmp=$Path+'.new'
    [IO.File]::WriteAllText($tmp,($Value | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($tmp,$Path,$Path+'.previous')}else{[IO.File]::Move($tmp,$Path)}
}
function Read-ArenaJson([string]$Path){Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}
function Assert-ArenaOffline {
    if(Get-Process mangosd -ErrorAction SilentlyContinue){throw '请先关闭世界服务器 mangosd，再操作；MySQL 保持运行。'}
}
function Test-ArenaListener([int]$Port){[bool](@(netstat -ano -p tcp | Select-String (':'+$Port+'\s+.*LISTENING')).Count)}
function Get-ArenaFingerprint {
    param($World,$Characters,[string]$Tools,[string]$ServerRoot)
    $tables=@(Read-ArenaRows $Characters $Tools "SELECT TABLE_NAME AS n FROM information_schema.tables WHERE TABLE_SCHEMA='tbccharacters' AND TABLE_TYPE='BASE TABLE' AND TABLE_NAME NOT LIKE 'codex_arena_%' ORDER BY TABLE_NAME;")
    if($tables.Count -lt 40){throw '角色库表数量不符。'}
    $names=@($tables | ForEach-Object {if($_.n -notmatch '^[a-z0-9_]+$'){throw '非法表名'};[string]$_.n}) -join ','
    $c=Invoke-ArenaSql $Characters $Tools "CHECKSUM TABLE $names;"
    if($c -match '\bNULL\b'){throw '无法计算角色数据校验和。'}
    $w=Invoke-ArenaSql $World $Tools 'CHECKSUM TABLE game_event,game_event_time,game_event_creature,game_event_creature_data,game_event_gameobject,game_event_mail,game_event_quest,conditions,npc_vendor,npc_vendor_template,creature_template;'
    $files=@('mangosd.exe','mangosd.conf','aiplayerbot.conf') | ForEach-Object {(Get-FileHash -LiteralPath (Join-Path $ServerRoot $_) -Algorithm SHA256).Hash}
    Get-ArenaHash ($c+"`n"+$w+"`n"+($files -join "`n"))
}
Export-ModuleMember -Function *-Arena*
