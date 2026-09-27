[CmdletBinding()]
param([ValidateSet('Menu','Status','Preseason','S1','S2','S3','Preview','ViewPreview','Settle','Undo','Recover','RestoreOriginal')][string]$Action='Menu',
      [string]$ServerRoot,[string]$ToolRoot,[switch]$Yes,
      [ValidateSet('','SqlFailure','AfterCommit')][string]$TestFault='')
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
foreach($module in @('Storage','RewardEngine','WorldLayout','NativeWinnerAdapter','Shadow')){Import-Module (Join-Path $PSScriptRoot "$module.psm1") -Force}
Initialize-ArenaProcessEnvironment
if(-not $ServerRoot){
    $ServerRoot=$PSScriptRoot
    if(-not (Test-Path (Join-Path $ServerRoot 'mangosd.conf'))){$ServerRoot=Split-Path $PSScriptRoot -Parent}
}
$ServerRoot=(Resolve-Path -LiteralPath $ServerRoot).Path
if(-not $ToolRoot){$ToolRoot=$ServerRoot}
$Tools=Join-Path $ToolRoot 'Database\bin'
$Root=Join-Path $ServerRoot '.arena-settlement-v5'
$Config=Join-Path $ServerRoot 'mangosd.conf'
$World=Read-ArenaConnection $Config 'WorldDatabaseInfo'
$Chars=Read-ArenaConnection $Config 'CharacterDatabaseInfo'
if($TestFault -and $Chars.Port -ne 13317){throw '故障注入仅允许独立测试端口 13317。'}
$binding=Get-ArenaHash ($ServerRoot.ToLowerInvariant()+'|'+$World.Port+'|'+$World.Database+'|'+$Chars.Database)
$lock=$null
$transcript=$false
function W([string]$sql){Invoke-ArenaSql $World $Tools $sql}
function C([string]$sql){Invoke-ArenaSql $Chars $Tools $sql}
function CR([string]$sql){@(Read-ArenaRows $Chars $Tools $sql)}
function WR([string]$sql){@(Read-ArenaRows $World $Tools $sql)}
function Scalar([string]$sql){$r=@(CR $sql);if($r.Count -ne 1){throw '查询结果数量异常。'};[string]@($r[0].PSObject.Properties)[0].Value}
function Fingerprint {Get-ArenaFingerprint $World $Chars $Tools $ServerRoot}
function Roster-Fingerprint {Get-ArenaHash (C 'CHECKSUM TABLE arena_team,arena_team_member,arena_team_stats;')}
function CharacterHash {
    $names=@(CR "SELECT TABLE_NAME AS n FROM information_schema.tables WHERE TABLE_SCHEMA='tbccharacters' AND TABLE_TYPE='BASE TABLE' AND TABLE_NAME NOT LIKE 'codex_arena_%' AND TABLE_NAME<>'game_event_status' ORDER BY TABLE_NAME;" | ForEach-Object {$_.n}) -join ','
    Get-ArenaHash ((C "CHECKSUM TABLE $names;")+(C 'SELECT * FROM game_event_status WHERE event NOT IN (53,54,55,56,2053,2054,2055,2056) ORDER BY event;'))
}
function Confirm([string]$Message){
    Write-Host $Message -ForegroundColor Yellow
    if(-not $Yes){if((Read-Host '输入 YES 或 Y 确认，其余取消').Trim() -notin @('YES','Y')){throw '已取消，未执行操作。'}}
}
function Get-Meta {
    if((Scalar "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema='tbccharacters' AND table_name='codex_arena_meta_v5';") -eq '0'){return $null}
    $m=@(CR 'SELECT * FROM codex_arena_meta_v5 WHERE id=1;')
    if($m.Count -eq 0 -and (Test-Path (Join-Path $Root 'schema-init.json'))){return $null}
    if($m.Count -ne 1 -or $m[0].binding -cne $binding){throw '控制记录不属于这个服务器目录；请勿移动或删除备份记录。'}
    if((Scalar "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema='tbccharacters' AND table_name IN ('codex_arena_meta_v5','codex_arena_history_v5','codex_arena_settlement_v1','codex_arena_titles_v1','codex_arena_awards_v1') AND engine='InnoDB';") -ne '5'){throw '结算账本的事务表结构发生变化，拒绝继续。'}
    if($m[0].stage -notin @('NotInstalled','Original','Preseason','S1','S2','S3','SettledS1','SettledS2','SettledS3')){throw '控制记录中的阶段无效。'}
    foreach($id in @($m[0].last_op,$m[0].last_settled)){if($id -and $id -notmatch '^[0-9a-f-]{36}$'){throw '控制记录中的操作编号无效。'}}
    if($m[0].stage -ne 'NotInstalled' -and -not (Test-Path (Join-Path $Root 'original.path'))){throw '数据库存在控制记录，但本地备份丢失。请恢复 .arena-settlement-v5 文件夹。'}
    return $m[0]
}
function Assert-Environment {
    Assert-ArenaOffline
    if($World.Database -ne 'tbcmangos' -or $Chars.Database -ne 'tbccharacters' -or $World.Port -ne $Chars.Port -or $World.User -ne $Chars.User){throw '数据库目标与已测试的 CM70 不符。'}
    foreach($key in @('LoginDatabaseInfo','LogsDatabaseInfo','PlayerbotDatabaseInfo')){
        $connection=Read-ArenaConnection $Config $key
        if($connection.Port -ne $World.Port -or $connection.User -ne $World.User -or $connection.Password -cne $World.Password){throw '数据库连接并非同一个本机实例，拒绝继续。'}
    }
    if((Get-FileHash (Join-Path $ServerRoot 'mangosd.exe')).Hash -ne '66CF3C31A26649B4BF6ABC690281508D464D42BC644F37B999EF4EB1D000793E'){throw '核心文件版本变化，拒绝应用旧版结算规则。'}
    if([DateTime]::Now.Year -ge 2049){throw '停车事件有效期将到期，必须先更新方案。'}
    foreach($row in WR (Get-ArenaWorldPreflightSql)){if([long]@($row.PSObject.Properties)[1].Value -ne 0){throw "世界数据不符合 V4 升级要求：$(@($row.PSObject.Properties)[0].Value)"}}
    foreach($r in WR 'SELECT entry,description FROM game_event WHERE entry IN (53,54,55,56) ORDER BY entry;'){
        if([string]$r.description -cne "竞技场评级赛第$([int]$r.entry-52)季"){throw '赛季事件描述不符，拒绝操作错误数据。'}
    }
    if((Scalar 'SELECT COUNT(*) AS n FROM game_event_status WHERE event=33;') -ne '0'){throw '自定义事件 33 活动，先查明原因。'}
    $bad=@(CR "SELECT table_name FROM information_schema.tables WHERE table_schema='tbccharacters' AND table_name IN ('characters','arena_team_stats','arena_team_member','mail','mail_items','item_instance') AND engine<>'InnoDB';")
    if($bad.Count){throw '关键角色表不支持事务，拒绝继续。'}
    $bot=[IO.File]::ReadAllText((Join-Path $ServerRoot 'aiplayerbot.conf'))
    if($bot -notmatch '(?m)^\s*AiPlayerbot.RandomBotAutoJoinBG\s*=\s*0\s*$'){throw '机器人自动排队配置变化，先检查准备期关闭条件。'}
}
function Ensure-Meta {
    $m=Get-Meta;if($m){return $m}
    $initFile=Join-Path $Root 'schema-init.json'
    if(Test-Path $initFile){if((Read-ArenaJson $initFile).Binding -cne $binding){throw '安装中断记录不属于本服务器。'}}else{
        if((Scalar "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema='tbccharacters' AND table_name LIKE 'codex_arena_%';") -ne '0'){throw '存在其他开发版结算记录，请勿混用。'}
        Write-ArenaJson $initFile ([pscustomobject]@{Binding=$binding})
    }
    C (Get-ArenaEngineSchemaSql) | Out-Null
    C @"
CREATE TABLE IF NOT EXISTS codex_arena_meta_v5 (id INT PRIMARY KEY,binding CHAR(64) NOT NULL,stage VARCHAR(20) NOT NULL,last_op CHAR(36) NOT NULL,last_settled CHAR(36) NOT NULL) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS codex_arena_history_v5 (operation_id CHAR(36) PRIMARY KEY,action_name VARCHAR(30) NOT NULL,stage_before VARCHAR(20) NOT NULL,stage_after VARCHAR(20) NOT NULL,created_utc DATETIME NOT NULL) ENGINE=InnoDB;
INSERT INTO codex_arena_meta_v5 SELECT 1,'$binding','NotInstalled','','' WHERE NOT EXISTS (SELECT 1 FROM codex_arena_meta_v5 WHERE id=1);
"@ | Out-Null
    Get-Meta
}
function Guard-Legacy {
    $file=Join-Path $Root 'legacy-guards.json'
    $records=@();if(Test-Path $file){$records=@(Read-ArenaJson $file)}
    $paths=@(Join-Path $ServerRoot 'ArenaSeasonControl.ps1')
    foreach($d in Get-ChildItem -LiteralPath $ServerRoot -Directory){$paths+=Join-Path $d.FullName 'ArenaSeasonControl.ps1'}
    foreach($path in $paths){
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){continue}
        if([IO.File]::ReadAllText($path) -notmatch 'CM70-ArenaSeasonController'){continue}
        $full=[IO.Path]::GetFullPath($path);$prefix=$ServerRoot.TrimEnd('\')+'\'
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw '旧控制器路径越界。'}
        $disabled=$full+'.disabled-by-v5'
        if(Test-Path -LiteralPath $disabled){throw '旧版停用备份已存在且原文件也存在，请勿混用多个版本。'}
        $existing=@($records | Where-Object {$_.Original -eq $full})
        if(-not $existing.Count){$records+=[pscustomobject]@{Original=$full;Disabled=$disabled;Hash=(Get-FileHash $full).Hash}}
        elseif($existing[0].Hash -cne (Get-FileHash $full).Hash){throw '旧版文件发生变化，拒绝覆盖旧备份。'}
        Write-ArenaJson $file @($records)
        [IO.File]::Move($full,$disabled)
        Write-Host "已暂时停用旧版入口：$(Split-Path (Split-Path $full -Parent) -Leaf)（文件保留，可恢复）"
    }
}
function Restore-Legacy {
    $file=Join-Path $Root 'legacy-guards.json';if(-not (Test-Path $file)){return}
    foreach($r in @(Read-ArenaJson $file)){
        $full=[IO.Path]::GetFullPath($r.Original)
        if(-not $full.StartsWith($ServerRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $r.Disabled -cne ($full+'.disabled-by-v5')){throw '旧版恢复路径无效。'}
        if(Test-Path -LiteralPath $r.Disabled){
            if((Test-Path -LiteralPath $full) -or (Get-FileHash $r.Disabled).Hash -cne $r.Hash){throw '旧版备份与当前文件冲突，已保留备份。'}
            [IO.File]::Move($r.Disabled,$full)
        }
    }
}
function Assert-ManagedLayout {
    $m=Get-Meta
    if(-not $m -or $m.stage -in @('NotInstalled','Original')){return}
    $active=0;if($m.stage -match '^S([123])$'){$active=52+[int]$Matches[1]}
    $expected=if($active){@{53=17;54=20;55=26}[$active]}else{0}
    $r=@(WR "SELECT COUNT(*) AS n FROM game_event g JOIN game_event_time t USING(entry) WHERE g.entry=56 AND g.schedule_type=1 AND g.occurence=525600 AND g.length=525600 AND g.linkedTo=0 AND t.start_time='2000-01-01 00:00:00' AND t.end_time='2050-01-01 00:00:00';")[0]
    if([int]$r.n -ne 1){throw '事件 56 保护设置被改变。请勿使用旧控制器，也不要开服。'}
    $r=@(WR "SELECT COUNT(*) AS n FROM game_event_creature WHERE ABS(event) IN (53,54,55,56);")[0]
    if([int]$r.n -ne $expected){throw '赛季内容与控制记录不符，可能使用了旧控制器。'}
    $r=@(WR "SELECT COUNT(*) AS n FROM game_event_creature WHERE ABS(event) IN (53,54,55,56) AND ABS(event)<>$active;")[0]
    if([int]$r.n -ne 0){throw '检测到错误赛季内容。'}
    $r=@(WR 'SELECT value1 AS n FROM conditions WHERE condition_entry=507;')[0]
    if([int]$r.n -ne 2056){throw 'S4 商品隔离被改变。'}
    $enabled=if($active){"56,$active"}else{'56'}
    $r=@(WR "SELECT COUNT(*) AS n FROM game_event g JOIN game_event_time t USING(entry) WHERE g.entry IN (53,54,55,56,2053,2054,2055,2056) AND (g.schedule_type<>1 OR g.linkedTo<>0 OR g.holiday<>0 OR g.EventGroup<>0 OR (g.entry IN ($enabled) AND (g.occurence<>525600 OR g.length<>525600 OR t.start_time<>'2000-01-01 00:00:00' OR t.end_time<>'2050-01-01 00:00:00')) OR (g.entry NOT IN ($enabled) AND (g.occurence<>0 OR g.length<>1 OR t.start_time<>'1970-01-01 00:00:00' OR t.end_time<>'1970-01-01 00:00:00')));")[0]
    if([int]$r.n -ne 0){throw '赛季时间或隔离事件被改变，请勿开服。'}
}
function Snapshot([string]$dir){
    New-Item -ItemType Directory -Path $dir | Out-Null
    $specs=@(@('game_event','entry IN (53,54,55,56,2053,2054,2055,2056)'),@('game_event_time','entry IN (53,54,55,56,2053,2054,2055,2056)'),@('game_event_creature','ABS(event) IN (53,54,55,56,2053,2054,2055,2056)'),@('game_event_creature_data','event IN (53,54,55,56,2053,2054,2055,2056)'),@('conditions','condition_entry=507'))
    foreach($s in $specs){Save-ArenaDump $World $Tools (Join-Path $dir ($s[0]+'.sql')) $s[0] $s[1]}
    foreach($table in @('arena_team_stats','arena_team_member')){Save-ArenaDump $Chars $Tools (Join-Path $dir ($table+'.sql')) $table}
    Save-ArenaDump $Chars $Tools (Join-Path $dir 'game_event_status.sql') 'game_event_status' 'event IN (53,54,55,56,2053,2054,2055,2056)'
    $titles=@(CR 'SELECT guid,HEX(knownTitles) AS titles,chosenTitle FROM characters ORDER BY guid;')
    $sql=@($titles | ForEach-Object {"UPDATE characters SET knownTitles=CONVERT(0x$($_.titles) USING utf8),chosenTitle=$([uint32]$_.chosenTitle) WHERE guid=$([uint32]$_.guid);"}) -join "`n"
    [IO.File]::WriteAllText((Join-Path $dir 'titles.sql'),$sql,(New-Object Text.UTF8Encoding($false)))
    foreach($f in @('mangosd.conf','aiplayerbot.conf')){Copy-Item -LiteralPath (Join-Path $ServerRoot $f) -Destination (Join-Path $dir ($f+'.original'))}
    $manifest=@{};Get-ChildItem $dir -Filter '*.sql' | ForEach-Object {$manifest[$_.Name]=(Get-FileHash $_.FullName).Hash}
    Write-ArenaJson (Join-Path $dir 'hashes.json') $manifest
}
function Verify-Snapshot([string]$dir){
    $m=Read-ArenaJson (Join-Path $dir 'hashes.json')
    foreach($p in $m.PSObject.Properties){if((Get-FileHash (Join-Path $dir $p.Name)).Hash -cne $p.Value){throw '备份内容损坏或被改动，拒绝恢复。'}}
}
function Restore-World([string]$dir){
    Verify-Snapshot $dir
    foreach($s in @(@('game_event','entry IN (53,54,55,56,2053,2054,2055,2056)'),@('game_event_time','entry IN (53,54,55,56,2053,2054,2055,2056)'),@('game_event_creature','ABS(event) IN (53,54,55,56,2053,2054,2055,2056)'),@('game_event_creature_data','event IN (53,54,55,56,2053,2054,2055,2056)'),@('conditions','condition_entry=507'))){
        $sql="DELETE FROM $($s[0]) WHERE $($s[1]);`n"+[IO.File]::ReadAllText((Join-Path $dir ($s[0]+'.sql')))
        W $sql | Out-Null
    }
    C ('DELETE FROM game_event_status WHERE event IN (53,54,55,56,2053,2054,2055,2056);'+[IO.File]::ReadAllText((Join-Path $dir 'game_event_status.sql'))) | Out-Null
}
function Restore-CharacterSql([string]$dir){
    Verify-Snapshot $dir
    $sql=[IO.File]::ReadAllText((Join-Path $dir 'titles.sql'))+"`n"
    foreach($t in @('arena_team_stats','arena_team_member')){$sql+="DELETE FROM $t;`n"+[IO.File]::ReadAllText((Join-Path $dir ($t+'.sql')))+"`n"}
    $sql
}
function Meta-Sql($meta,[string]$id,[string]$action,[string]$stage,[string]$settled){
    "UPDATE codex_arena_meta_v5 SET stage='$stage',last_op='$id',last_settled='$settled' WHERE id=1; INSERT INTO codex_arena_history_v5 VALUES ('$id','$action','$($meta.stage)','$stage',UTC_TIMESTAMP());"
}
function Apply-Operation([string]$name,[string]$target,[string]$characterSql,[string]$settledId='',[string]$restoreDir='',[string]$planFile='',[string]$expectedBefore=''){
    Assert-Environment
    $meta=Ensure-Meta;$id=[guid]::NewGuid().ToString();$dir=Join-Path $Root $id
    $before=Fingerprint
    if($expectedBefore -and $before -cne $expectedBefore){throw '确认期间数据发生变化，请重新预览。'}
    Snapshot $dir
    if($planFile){Copy-Item -LiteralPath $planFile -Destination (Join-Path $dir 'settled-plan.json')}
    if((Fingerprint) -cne $before){throw '备份期间数据发生变化，拒绝执行。'}
    if(-not (Test-Path (Join-Path $Root 'original.path'))){[IO.File]::WriteAllText((Join-Path $Root 'original.path'),$id)}
    if($name -eq 'Settle'){$settledId=$id}
    $journal=[pscustomobject]@{Id=$id;Action=$name;Target=$target;BeforeMeta=$meta;Before=$before;BeforeChars=(CharacterHash);Phase='Prepared';After='';CanUndo=$false;SettledId=$settledId}
    Write-ArenaJson (Join-Path $dir 'journal.json') $journal
    [IO.File]::WriteAllText((Join-Path $Root 'pending.path'),$id)
    try{
        if($target -notin @('Original','NotInstalled')){Guard-Legacy}
        if($restoreDir){Restore-World $restoreDir}else{
            W (New-ArenaWorldLayoutSql $target) | Out-Null
            C 'DELETE FROM game_event_status WHERE event IN (53,54,55,56,2053,2054,2055,2056);' | Out-Null
        }
        $journal.Phase='WorldApplied';Write-ArenaJson (Join-Path $dir 'journal.json') $journal
        Assert-ArenaOffline
        if((CharacterHash) -cne $journal.BeforeChars){throw '执行期间角色数据发生变化，拒绝提交。'}
        # All character updates and metadata commit in ONE connection/transaction.
        if(-not $characterSql){$characterSql='START TRANSACTION;'}
        $characterSql=$characterSql.Replace('__OPERATION_ID__',$id)
        $characterSql=[regex]::Replace($characterSql,'(?is)COMMIT;\s*$','')
        if($TestFault -eq 'SqlFailure'){$characterSql+=' SELECT * FROM codex_deliberately_missing_test_table;'}
        $characterSql+="`n"+(Meta-Sql $meta $id $name $target $settledId)+"`nCOMMIT;"
        C $characterSql | Out-Null
        if($TestFault -eq 'AfterCommit'){throw '模拟提交后进程中断。'}
        if($target -in @('Original','NotInstalled')){Restore-Legacy}
        $journal.Phase='Complete';$journal.After=Fingerprint;$journal.CanUndo=$true
        Write-ArenaJson (Join-Path $dir 'journal.json') $journal
        Remove-Item -LiteralPath (Join-Path $Root 'pending.path')
        Write-Host "操作完成：$target。现在可以启动服务器。" -ForegroundColor Green
        return $id
    }catch{
        $m=Get-Meta
        if($m.last_op -eq $id){throw '角色事务已经提交，但收尾未完成。不要重复结算；请使用菜单“恢复中断操作”。'}
        if((CharacterHash) -cne $journal.BeforeChars){throw '操作失败且角色数据变化。保留了备份，请勿开服或手工恢复。'}
        Restore-World $dir
        if($meta.stage -in @('NotInstalled','Original')){Restore-Legacy}
        $journal.Phase='RolledBack';Write-ArenaJson (Join-Path $dir 'journal.json') $journal
        Remove-Item -LiteralPath (Join-Path $Root 'pending.path')
        throw
    }
}
function Show-Status {
    $m=Get-Meta
    if(-not $m){Write-Host '尚未安装结算控制器。首次选择准备期或 S1 会安装保护。';return}
    $labels=@{NotInstalled='尚未安装';Preseason='准备期（不结算）';S1='S1 进行中';S2='S2 进行中';S3='S3 进行中';SettledS1='S1 已结算，等待 S2';SettledS2='S2 已结算，等待 S3';SettledS3='S3 已结算';Original='已恢复安装前场景'}
    Write-Host ("记录中的阶段："+$labels[[string]$m.stage]) -ForegroundColor Cyan
    if($m.stage -notin @('Original','NotInstalled')){
        try{Assert-ManagedLayout;Write-Host '场景设置校验正常。事件 56 是内部保护，不表示 S4 开放。'}catch{Write-Host $_.Exception.Message -ForegroundColor Red}
    }
    if(Test-Path (Join-Path $Root 'pending.path')){Write-Host '发现中断操作：只可执行恢复中断操作。' -ForegroundColor Yellow}
}
function Make-Preview {
    Assert-Environment;Assert-ManagedLayout;$m=Get-Meta
    if(-not $m -or $m.stage -notmatch '^S([123])$'){throw '只有正在进行的 S1、S2、S3 可以结算预览。准备期不可以。'}
    $season=[int]$Matches[1];$stamp=[guid]::NewGuid().ToString();$dir=Join-Path $Root ('preview-'+$stamp)
    $hash=Fingerprint;$before=@(CR 'SELECT guid,knownTitles,chosenTitle FROM characters ORDER BY guid;')
    $result=Invoke-ArenaShadow $ServerRoot $Tools $dir $season
    Assert-ArenaOffline
    if((Fingerprint) -cne $hash){throw '计算期间正式数据发生变化，本次预览作废。'}
    $awards=@(ConvertFrom-NativeArenaWinners $season $before $result.Characters $result.Teams $result.Members)
    $plan=New-ArenaRewardPlan $season $awards $before
    $plan | Add-Member -NotePropertyName Fingerprint -NotePropertyValue $hash
    $plan | Add-Member -NotePropertyName RosterFingerprint -NotePropertyValue (Roster-Fingerprint)
    $plan | Add-Member -NotePropertyName ResetStats -NotePropertyValue $result.ResetStats
    $plan | Add-Member -NotePropertyName ResetMembers -NotePropertyValue $result.ResetMembers
    Write-ArenaJson (Join-Path $dir 'plan.json') $plan
    Write-ArenaJson (Join-Path $Root 'preview.json') ([pscustomobject]@{Directory=('preview-'+$stamp);Hash=(Get-FileHash (Join-Path $dir 'plan.json')).Hash})
    Write-Host "预览完成：$($plan.Rewards.Count) 个角色获奖，其中 $(@($plan.Rewards | Where-Object {$_.Mount -gt 0}).Count) 个角色获坐骑。正式服尚未发奖。" -ForegroundColor Green
    $plan.Rewards | Export-Csv -LiteralPath (Join-Path $dir '获奖名单.csv') -NoTypeInformation -Encoding UTF8
    $names=@{};foreach($r in CR 'SELECT guid,name FROM characters ORDER BY guid;'){$names[[uint32]$r.guid]=$r.name}
    $tierNames=@{Champion='赛季冠军';Gladiator='角斗士';Duelist='决斗者';Rival='竞争者';Challenger='挑战者'}
    $lines=@("S$season 结算预览（尚未发奖）","获奖角色：$($plan.Rewards.Count)",'荣誉和竞技场点数：保留','')
    foreach($r in $plan.Rewards){$mount=if([int]$r.Mount -gt 0){'，本赛季坐骑'}else{''};$lines+="$($names[[uint32]$r.Guid])：$($tierNames[[string]$r.Tier])$mount"}
    [IO.File]::WriteAllLines((Join-Path $dir '预览结果.txt'),[string[]]$lines,(New-Object Text.UTF8Encoding($true)))
    Write-Host "完整名单：$(Join-Path $dir '预览结果.txt')"
}
function Execute-Settle {
    Assert-Environment;Assert-ManagedLayout;$m=Get-Meta
    if(-not $m -or $m.stage -notmatch '^S([123])$'){throw '当前不是可结算的进行中赛季。'}
    $season=[int]$Matches[1]
    if(-not (Test-Path (Join-Path $Root 'preview.json'))){throw '请先选择“结算预览”。'}
    $p=Read-ArenaJson (Join-Path $Root 'preview.json')
    if($p.Directory -notmatch '^preview-[0-9a-f-]{36}$'){throw '预览路径非法。'}
    $file=Join-Path (Join-Path $Root $p.Directory) 'plan.json'
    if((Get-FileHash $file).Hash -cne $p.Hash){throw '预览文件被修改。'}
    $plan=Read-ArenaJson $file
    if($plan.Season -ne $season -or $plan.Fingerprint -cne (Fingerprint)){throw '预览已过期，请重新预览后结算。'}
    Confirm "即将结算 S$season：发放 $($plan.Rewards.Count) 份头衔奖励，关闭竞技场入口。不会清空荣誉或竞技场点数。"
    $max=@(CR 'SELECT COALESCE((SELECT MAX(id) FROM mail),0) AS mail,COALESCE((SELECT MAX(guid) FROM item_instance),0) AS item;')[0]
    $dummy=[guid]::NewGuid();$sql=New-ArenaSettlementSql $plan $dummy $p.Hash ([long]$max.mail) ([long]$max.item)
    $sql=$sql.Replace($dummy.ToString(),'__OPERATION_ID__')
    # Reissuing after a verified undo is allowed; prior operation remains in
    # history and its immutable on-disk snapshot. Active settlements still fail.
    $retry="DELETE t FROM codex_arena_titles_v1 t JOIN codex_arena_settlement_v1 s USING(season) WHERE s.season=$season AND s.status='Undone'; DELETE a FROM codex_arena_awards_v1 a JOIN codex_arena_settlement_v1 s USING(season) WHERE s.season=$season AND s.status='Undone'; DELETE FROM codex_arena_settlement_v1 WHERE season=$season AND status='Undone';"
    $sql=$sql.Replace('START TRANSACTION;',('START TRANSACTION;'+$retry))
    Apply-Operation 'Settle' "SettledS$season" $sql '' '' $file $plan.Fingerprint | Out-Null
}
function Start-Season([string]$state){
    Assert-Environment;Assert-ManagedLayout;$m=Get-Meta
    $current=if($m){[string]$m.stage}else{'NotInstalled'}
    $sql='START TRANSACTION;';$settled=if($m){[string]$m.last_settled}else{''};$expectedBefore=''
    if($state -in @('Preseason','S1')){
        if($current -notin @('NotInstalled','Original','Preseason','S1')){throw '已有赛季进度，不能跳回准备期或 S1；如需撤销请使用撤销选项。'}
        if($m -and (Scalar "SELECT COUNT(*) AS n FROM codex_arena_settlement_v1 WHERE status='Settled';") -ne '0'){throw '已有正式结算，不能跳回。'}
    }else{
        $s=[int]$state.Substring(1);if($current -ne "SettledS$($s-1)"){throw "需要先结算 S$($s-1)。"}
        $settledPlan=Join-Path (Join-Path $Root $settled) 'settled-plan.json'
        $savedHash=Scalar "SELECT plan_hash FROM codex_arena_settlement_v1 WHERE season=$($s-1) AND operation_id='$settled' AND status='Settled';"
        if((Get-FileHash $settledPlan).Hash -cne $savedHash){throw '已结算的名单文件被改动，拒绝执行队伍重置。'}
        $plan=Read-ArenaJson $settledPlan
        $expectedBefore=Fingerprint
        if(-not $plan.PSObject.Properties['RosterFingerprint'] -or $plan.RosterFingerprint -cne (Roster-Fingerprint)){
            Write-Host '队伍名单已变化，正在副本中重新计算下一季重置结果；不会再次发奖。'
            $dir=Join-Path $Root ('reset-'+[guid]::NewGuid().ToString())
            $reset=Invoke-ArenaShadow $ServerRoot $Tools $dir ($s-1)
            Assert-ArenaOffline
            if((Fingerprint) -cne $expectedBefore){throw '重置计算期间正式数据变化，请重试。'}
            $plan=$reset
        }
        foreach($r in $plan.ResetStats){$sql+="UPDATE arena_team_stats SET rating=$([uint32]$r.rating),games_week=0,wins_week=0,games_season=0,wins_season=0,rank=0 WHERE arenateamid=$([uint32]$r.arenateamid);"}
        foreach($r in $plan.ResetMembers){$sql+="UPDATE arena_team_member SET played_week=0,wons_week=0,played_season=0,wons_season=0,personal_rating=$([uint32]$r.personal_rating) WHERE arenateamid=$([uint32]$r.arenateamid) AND guid=$([uint32]$r.guid);"}
    }
    Confirm "切换到 $state。需已关闭世界服务器；会先备份。"
    Apply-Operation $state $state $sql $settled '' '' $expectedBefore | Out-Null
}
function Undo-Last {
    Assert-Environment;$m=Get-Meta
    if(-not $m -or -not $m.last_op){throw '没有可撤销操作。'}
    $dir=Join-Path $Root $m.last_op;$j=Read-ArenaJson (Join-Path $dir 'journal.json')
    if($j.Action -eq 'Undo'){throw '最近一次已是撤销操作，不支持再次撤销这个撤销。可以重新预览并结算。'}
    if(-not $j.CanUndo -or $j.After -cne (Fingerprint)){throw '操作后数据已变化（可能已开服或领取奖励），为保护进度禁止撤销。'}
    Confirm '撤销最近一次操作，恢复该次操作之前的数据。'
    $sql=if($j.Action -eq 'Settle'){New-ArenaUndoSql ([int]$j.Target.Substring(8)) ([guid]$j.Id)}else{'START TRANSACTION;'}
    $sql=[regex]::Replace($sql,'(?is)COMMIT;\s*$','')
    $sql+="`n"+(Restore-CharacterSql $dir)
    Apply-Operation 'Undo' $j.BeforeMeta.stage $sql $j.BeforeMeta.last_settled $dir | Out-Null
}
function Recover-Pending {
    Assert-Environment;$file=Join-Path $Root 'pending.path'
    if(-not (Test-Path $file)){Write-Host '没有中断操作。';return}
    $id=[IO.File]::ReadAllText($file);if($id -notmatch '^[0-9a-f-]{36}$'){throw '中断记录路径无效。'}
    $dir=Join-Path $Root $id;$j=Read-ArenaJson (Join-Path $dir 'journal.json');$m=Get-Meta
    Confirm '检查并恢复上次中断的控制器操作；不会重复发奖。'
    if($m.last_op -eq $id){
        if($m.stage -in @('Original','NotInstalled')){Restore-Legacy}else{Guard-Legacy}
        $j.Phase='Complete';$j.After=Fingerprint;$j.CanUndo=$false
        Write-Host '已确认事务提交；保留现有奖励。因缺少完整收尾记录，本次不提供自动撤销。'
    }else{
        if((CharacterHash) -cne $j.BeforeChars){throw '角色数据已发生变化，无法安全自动恢复。'}
        Restore-World $dir;$j.Phase='RolledBack'
        if($j.BeforeMeta.stage -in @('NotInstalled','Original')){Restore-Legacy}
    }
    Write-ArenaJson (Join-Path $dir 'journal.json') $j
    Remove-Item -LiteralPath $file
}
function Run-Action([string]$a){
    if($a -eq 'Status'){Show-Status;return}
    if($a -eq 'ViewPreview'){
        $path=Join-Path $Root 'preview.json'
        if(-not (Test-Path $path)){throw '还没有预览名单，请先选择 5。'}
        $p=Read-ArenaJson $path
        if($p.Directory -notmatch '^preview-[0-9a-f-]{36}$'){throw '预览路径无效。'}
        $textFile=Join-Path (Join-Path $Root $p.Directory) '预览结果.txt'
        if(-not (Test-Path $textFile)){throw '这份旧预览没有中文名单，请重新选择 5。'}
        Write-Host '以下是当时生成的预览。是否已经结算，请以菜单显示的阶段为准。'
        Get-Content -LiteralPath $textFile -Encoding UTF8 | ForEach-Object {Write-Host ($_.Replace('（尚未发奖）','（生成预览时尚未发奖）'))}
        Write-Host '这是最近一次预览。之后开过服或数据有变化时，必须重新预览。'
        return
    }
    if($a -eq 'Recover'){Recover-Pending;return}
    if(Test-Path (Join-Path $Root 'pending.path')){throw '存在中断操作，先选择恢复中断操作。'}
    switch($a){
        'Preseason'{Start-Season 'Preseason'};'S1'{Start-Season 'S1'};'S2'{Start-Season 'S2'};'S3'{Start-Season 'S3'}
        'Preview'{Make-Preview};'Settle'{Execute-Settle};'Undo'{Undo-Last}
        'RestoreOriginal'{
            Assert-Environment;$m=Get-Meta
            if(-not $m){throw '尚无安装前备份。'}
            if((Scalar "SELECT COUNT(*) AS n FROM codex_arena_settlement_v1 WHERE status='Settled';") -ne '0'){throw '已有结算奖励，恢复原版自动机制可能改坏这些奖励，本版禁止此操作。'}
            $id=[IO.File]::ReadAllText((Join-Path $Root 'original.path'));if($id -notmatch '^[0-9a-f-]{36}$'){throw '原始备份路径无效。'}
            Confirm '警告：恢复安装前的世界事件，将重新启用原端潜在的自动结算。角色奖励和点数不会被回档。'
            Apply-Operation 'RestoreOriginal' 'Original' 'START TRANSACTION;' $m.last_settled (Join-Path $Root $id) | Out-Null
        }
    }
}
try{
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $lock=[IO.File]::Open((Join-Path $ServerRoot '.arena-season-controller.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $logRoot=Join-Path $Root 'logs';New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    Start-Transcript -Path (Join-Path $logRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.log')) | Out-Null
    $transcript=$true
    if($Action -ne 'Menu'){Run-Action $Action}else{
        while($true){
            Write-Host "`n====== CM70 竞技场 S1–S3 控制器 V5 ======" -ForegroundColor Cyan
            Show-Status
            Write-Host "1. 准备期（不结算）`n2. 开始 S1`n3. 开始 S2`n4. 开始 S3`n5. 当前赛季结算预览（不发奖）`n6. 当前赛季正式结算`n7. 查看状态`n8. 撤销最近一次操作`n9. 恢复中断操作`n10. 恢复安装前场景`n11. 查看最近预览的获奖名单`n0. 退出"
            $choice=Read-Host '请选择';if($choice -eq '0'){break}
            $map=@{'1'='Preseason';'2'='S1';'3'='S2';'4'='S3';'5'='Preview';'6'='Settle';'7'='Status';'8'='Undo';'9'='Recover';'10'='RestoreOriginal';'11'='ViewPreview'}
            if($map.ContainsKey($choice)){try{Run-Action $map[$choice]}catch{Write-Host $_.Exception.Message -ForegroundColor Red};[void](Read-Host '按回车返回菜单')}
        }
    }
}finally{if($transcript){Stop-Transcript | Out-Null};if($lock){$lock.Dispose()}}
