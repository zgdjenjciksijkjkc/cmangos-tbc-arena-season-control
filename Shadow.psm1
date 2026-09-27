Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'Storage.psm1')
Import-Module (Join-Path $PSScriptRoot 'WorldLayout.psm1')
function Set-ShadowSetting([string]$Text,[string]$Key,[string]$Value){
    $p='(?m)^\s*'+[regex]::Escape($Key)+'\s*=.*$'
    if([regex]::IsMatch($Text,$p)){[regex]::Replace($Text,$p,($Key+' = '+$Value))}else{$Text+"`r`n$Key = $Value`r`n"}
}
function Invoke-ArenaShadow {
    param([string]$ServerRoot,[string]$Tools,[string]$Directory,[ValidateRange(1,3)][int]$Season)
    Assert-ArenaOffline
    if((Test-ArenaListener 13318) -or (Test-ArenaListener 18086)){throw '副本端口 13318 或 18086 被占用，未启动任何副本。'}
    if(Test-Path -LiteralPath $Directory){throw '副本目录已存在，拒绝覆盖。'}
    # MySQL 5.7 still hits MAX_PATH in long performance_schema file names.
    # Keep its disposable data/runtime in a short, unique temporary directory.
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('cm70-arena-'+[guid]::NewGuid().ToString('N'))
    $runtime=Join-Path $scratch 'runtime';$data=Join-Path $scratch 'data'
    foreach($d in @($Directory,$scratch,$runtime,$data,(Join-Path $runtime 'logs'))){New-Item -ItemType Directory -Path $d | Out-Null}
    [IO.File]::WriteAllText((Join-Path $scratch 'generated-by-v5.txt'),'Disposable isolated arena evaluation only')
    $config=Join-Path $ServerRoot 'mangosd.conf';$raw=[IO.File]::ReadAllText($config)
    $matches=[regex]::Matches($raw,'(?m)^\s*(\w+DatabaseInfo)\s*=\s*"([^"]+)"')
    if($matches.Count -ne 5){throw '数据库配置数量与测试版本不符。'}
    $connections=@{}
    foreach($m in $matches){$c=Read-ArenaConnection $config $m.Groups[1].Value;$connections[$c.Database]=$c}
    $login=Read-ArenaConnection $config 'LoginDatabaseInfo'
    $armory=@(Read-ArenaRows $login $Tools "SELECT SCHEMA_NAME AS n FROM information_schema.schemata WHERE SCHEMA_NAME='tbcarmory';")
    if($armory.Count){$connections['tbcarmory']=[pscustomobject]@{Host=$login.Host;Port=$login.Port;User=$login.User;Password=$login.Password;Database='tbcarmory'}}
    foreach($db in @($connections.Keys | Sort-Object)){
        Write-Host "正在复制 $db，正式库只读……"
        Save-ArenaDump $connections[$db] $Tools (Join-Path $Directory "$db.sql")
    }
    Get-ChildItem -LiteralPath $ServerRoot -File | Where-Object {$_.Extension -eq '.dll' -or $_.Name -in @('mangosd.exe','mangosd.lar')} | Copy-Item -Destination $runtime
    $password=[guid]::NewGuid().ToString('N')
    foreach($m in $matches){$db=($m.Groups[2].Value.Split(';'))[4];$raw=Set-ShadowSetting $raw $m.Groups[1].Value ('"127.0.0.1;13318;root;'+$password+';'+$db+'"')}
    $dataMatch=[regex]::Match($raw,'(?m)^\s*DataDir\s*=\s*"([^"]+)"')
    if(-not $dataMatch.Success){throw 'DataDir 未找到。'}
    $gameData=$dataMatch.Groups[1].Value
    if(-not [IO.Path]::IsPathRooted($gameData)){$gameData=Join-Path $ServerRoot $gameData}
    if(-not (Test-Path -LiteralPath $gameData)){throw '游戏数据目录不存在。'}
    $settings=@{DataDir=('"'+$gameData.Replace('\','/')+'"');LogsDir='"logs"';BindIP='"127.0.0.1"';WorldServerPort='18086';'Ra.Enable'='0';'SOAP.Enabled'='0';'Metric.Enable'='0';'Console.Enable'='1';PidFile='"shadow.pid"';MaxCoreStuckTime='0';'Arena.AutoDistributePoints'='0'}
    foreach($key in $settings.Keys){$raw=Set-ShadowSetting $raw $key $settings[$key]}
    [IO.File]::WriteAllText((Join-Path $runtime 'mangosd.conf'),$raw,(New-Object Text.UTF8Encoding($false)))
    foreach($file in @('aiplayerbot.conf','ahbot.conf')){
        $text=[IO.File]::ReadAllText((Join-Path $ServerRoot $file))
        if($file -eq 'aiplayerbot.conf'){
            $text=Set-ShadowSetting $text 'AiPlayerbot.RandomBotAutologin' '0'
            $text=Set-ShadowSetting $text 'AiPlayerbot.RandomBotAutoJoinBG' '0'
        }
        [IO.File]::WriteAllText((Join-Path $runtime $file),$text,(New-Object Text.UTF8Encoding($false)))
    }
    # Validate the final generated config independently before launching it.
    $check=[regex]::Matches([IO.File]::ReadAllText((Join-Path $runtime 'mangosd.conf')),'(?m)^\s*\w+DatabaseInfo\s*=\s*"([^"]+)"')
    foreach($m in $check){if($m.Groups[1].Value -notmatch ('^127\.0\.0\.1;13318;root;'+$password+';tbc[a-z]+$')){throw '副本隔离校验失败。'}}
    $basedir=Split-Path $Tools -Parent
    $init=Start-Process -FilePath (Join-Path $Tools 'mysqld.exe') -ArgumentList @('--no-defaults','--initialize-insecure',('"--basedir='+$basedir+'"'),('"--datadir='+$data+'"'),'--log_syslog=0','--console') -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput (Join-Path $Directory 'mysql-init.out') -RedirectStandardError (Join-Path $Directory 'mysql-init.err')
    if($init.ExitCode -ne 0){throw '独立数据库初始化失败，参见 mysql-init.err。'}
    $dbProcess=$null;$worldProcess=$null
    $shadow=[pscustomobject]@{Host='127.0.0.1';Port=13318;User='root';Password='';Database='mysql'}
    try{
        $dbProcess=Start-Process -FilePath (Join-Path $Tools 'mysqld.exe') -ArgumentList @('--no-defaults',('"--basedir='+$basedir+'"'),('"--datadir='+$data+'"'),'--port=13318','--bind-address=127.0.0.1','--max-allowed-packet=256M','--innodb-buffer-pool-size=256M','--event-scheduler=OFF','--skip-log-bin','--log_syslog=0','--console') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Directory 'mysql.out') -RedirectStandardError (Join-Path $Directory 'mysql.err')
        $limit=[DateTime]::UtcNow.AddSeconds(30)
        while(-not (Test-ArenaListener 13318)){
            if($dbProcess.HasExited -or [DateTime]::UtcNow -gt $limit){throw '副本 MySQL 启动失败。'}
            Start-Sleep -Milliseconds 300
        }
        Invoke-ArenaSql $shadow $Tools "ALTER USER 'root'@'localhost' IDENTIFIED BY '$password';" | Out-Null
        $shadow.Password=$password
        foreach($db in @($connections.Keys | Sort-Object)){
            Write-Host "正在加载副本 $db……"
            $shadow.Database='mysql';Invoke-ArenaSql $shadow $Tools "CREATE DATABASE $db CHARACTER SET utf8;" | Out-Null
            $shadow.Database=$db;Invoke-ArenaSql -Connection $shadow -Tools $Tools -File (Join-Path $Directory "$db.sql") | Out-Null
        }
        $shadow.Database='tbcmangos';Invoke-ArenaSql $shadow $Tools (New-ArenaWorldLayoutSql 'Preseason') | Out-Null
        $shadow.Database='tbcrealmd';Invoke-ArenaSql $shadow $Tools "UPDATE realmlist SET address='127.0.0.1',port=18086;" | Out-Null
        $shadow.Database='tbccharacters';Invoke-ArenaSql $shadow $Tools 'DELETE FROM game_event_status WHERE event IN (53,54,55,56,2053,2054,2055,2056);' | Out-Null
        Write-Host '正在让原核心计算副本中的结算名单，通常需要数分钟……'
        $si=New-Object Diagnostics.ProcessStartInfo
        $si.FileName=Join-Path $runtime 'mangosd.exe';$si.WorkingDirectory=$runtime
        $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
        $si.StandardOutputEncoding=[Text.Encoding]::GetEncoding(936);$si.StandardErrorEncoding=[Text.Encoding]::GetEncoding(936)
        $worldProcess=[Diagnostics.Process]::Start($si)
        $stdout=$worldProcess.StandardOutput.ReadToEndAsync();$stderr=$worldProcess.StandardError.ReadToEndAsync()
        $limit=[DateTime]::UtcNow.AddSeconds(360);$notice=[DateTime]::UtcNow.AddSeconds(20)
        while(-not (Test-ArenaListener 18086)){
            if($worldProcess.HasExited -or [DateTime]::UtcNow -gt $limit){throw '副本世界服务未正常就绪。'}
            if([DateTime]::UtcNow -ge $notice){Write-Host '副本仍在加载机器人数据，请稍候……';$notice=[DateTime]::UtcNow.AddSeconds(20)}
            Start-Sleep -Milliseconds 500
        }
        $teams=@(Read-ArenaRows $shadow $Tools 'SELECT t.arenateamid,t.type,s.rating FROM arena_team t JOIN arena_team_stats s USING(arenateamid) ORDER BY t.arenateamid;')
        $members=@(Read-ArenaRows $shadow $Tools 'SELECT * FROM arena_team_member ORDER BY arenateamid,guid;')
        $worldProcess.StandardInput.WriteLine("arena sendRewards $Season");$worldProcess.StandardInput.Flush()
        Start-Sleep -Seconds 3
        $worldProcess.StandardInput.WriteLine('server shutdown 1');$worldProcess.StandardInput.Flush()
        # Release the core console thread's blocking getline on shutdown.
        $worldProcess.StandardInput.Close()
        if(-not $worldProcess.WaitForExit(60000)){throw '副本结算后关服超时，拒绝使用这份结果。'}
        if($worldProcess.ExitCode -ne 0){throw '副本异常退出，拒绝使用这份结果。'}
        $completion=@(Read-ArenaRows $shadow $Tools 'SELECT COALESCE((SELECT SUM(games_season) FROM arena_team_stats),0) AS games,COALESCE((SELECT SUM(arenaPoints) FROM characters),0) AS points;')[0]
        if([long]$completion.games -ne 0 -or [long]$completion.points -ne 0){throw '副本未完成原端结算，拒绝把部分结果用于正式服。'}
        $result=[pscustomobject]@{
            Teams=$teams;Members=$members
            Characters=@(Read-ArenaRows $shadow $Tools 'SELECT guid,knownTitles,chosenTitle FROM characters ORDER BY guid;')
            ResetStats=@(Read-ArenaRows $shadow $Tools 'SELECT * FROM arena_team_stats ORDER BY arenateamid;')
            ResetMembers=@(Read-ArenaRows $shadow $Tools 'SELECT * FROM arena_team_member ORDER BY arenateamid,guid;')
        }
        Write-ArenaJson (Join-Path $Directory 'native-result.json') $result
        return $result
    }finally{
        if($worldProcess){
            if(-not $worldProcess.HasExited){$worldProcess.Kill();$worldProcess.WaitForExit()}
            [IO.File]::WriteAllText((Join-Path $Directory 'world.out'),$stdout.GetAwaiter().GetResult())
            [IO.File]::WriteAllText((Join-Path $Directory 'world.err'),$stderr.GetAwaiter().GetResult())
            $worldProcess.Dispose()
        }
        if($dbProcess -and -not $dbProcess.HasExited){
            $old=$env:MYSQL_PWD
            try{$env:MYSQL_PWD=$shadow.Password;& (Join-Path $Tools 'mysqladmin.exe') --no-defaults --protocol=TCP --host=127.0.0.1 --port=13318 --user=root shutdown 2>$null | Out-Null}finally{$env:MYSQL_PWD=$old}
            if(-not $dbProcess.WaitForExit(15000)){$dbProcess.Kill();$dbProcess.WaitForExit()}
        }
        # Only this generated scratch tree is removed. SQL input and result
        # evidence remain in the durable preview directory.
        $resolved=[IO.Path]::GetFullPath($scratch)
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^cm70-arena-[0-9a-f]{32}$' -and (Test-Path (Join-Path $resolved 'generated-by-v5.txt'))){
            try{Remove-Item -LiteralPath $resolved -Recurse -Force}catch{Write-Warning '临时副本未能清理；正式数据未受影响。'}
        }
    }
}
Export-ModuleMember -Function Invoke-ArenaShadow
