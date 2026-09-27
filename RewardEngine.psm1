# Character-side settlement engine. No native arena command is invoked.
# Production integration is deliberately not exposed until policy/world tests pass.
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'

function Get-ArenaReward {
    param([ValidateRange(1,3)][int]$Season,[ValidateSet('Champion','Gladiator','Duelist','Rival','Challenger')][string]$Tier)
    $title=@{Champion=42;Gladiator=42;Duelist=43;Rival=44;Challenger=45}[$Tier]
    if($Tier -eq 'Champion' -and $Season -eq 2){$title=62}
    if($Tier -eq 'Champion' -and $Season -eq 3){$title=71}
    $mount=0
    if($Tier -in @('Champion','Gladiator')){$mount=@{1=30609;2=34092;3=37676}[$Season]}
    [pscustomobject]@{Season=$Season;Tier=$Tier;Title=$title;Bit=@{42=29;43=30;44=31;45=32;62=37;71=40}[$title];Mount=$mount}
}

function Get-ArenaTitleValue {
    param([string]$KnownTitles,[int[]]$AddBits=@(),[switch]$ExpireTemporary)
    if($KnownTitles -notmatch '^\s*\d+\s+\d+\s*$'){throw 'Invalid knownTitles serialization.'}
    $v=@($KnownTitles.Trim() -split '\s+' | ForEach-Object {[uint64]::Parse($_)})
    if($v[0] -gt 4294967295 -or $v[1] -gt 4294967295){throw 'Title word overflow.'}
    if($ExpireTemporary){$v[0]=$v[0] -band [uint64]536870911;$v[1]=$v[1] -band [uint64]4294967294}
    foreach($bit in $AddBits){
        if($bit -lt 0 -or $bit -gt 63){throw 'Invalid title bit.'}
        $index=[int][Math]::Floor($bit/32)
        $v[$index]=$v[$index] -bor ([uint64]1 -shl ($bit%32))
    }
    return "$($v[0]) $($v[1]) "
}

function New-ArenaRewardPlan {
    param([ValidateRange(1,3)][int]$Season,[object[]]$Awards,[object[]]$Characters)
    # Awards are supplied by a separately verified ranking policy, not read from
    # the unreliable stored rank field. This layer merges multi-bracket winners.
    $priority=@{Champion=0;Gladiator=1;Duelist=2;Rival=3;Challenger=4}
    $best=@{};$charactersById=@{}
    foreach($c in $Characters){
        $id=[uint32]$c.guid
        if($charactersById.ContainsKey($id)){throw 'Duplicate character.'}
        $charactersById[$id]=$c
    }
    foreach($a in $Awards){
        $id=[uint32]$a.Guid
        if(-not $charactersById.ContainsKey($id)){throw "Unknown reward receiver $id."}
        if(-not $priority.ContainsKey([string]$a.Tier)){throw 'Unknown reward tier.'}
        if(-not $best.ContainsKey($id) -or $priority[[string]$a.Tier] -lt $priority[[string]$best[$id]]){$best[$id]=[string]$a.Tier}
    }
    $changes=@();$rewards=@()
    foreach($id in @($charactersById.Keys | Sort-Object)){
        $c=$charactersById[$id];$bits=@()
        if($best.ContainsKey($id)){
            $r=Get-ArenaReward -Season $Season -Tier $best[$id]
            $bits=@($r.Bit)
            $rewards += [pscustomobject]@{Guid=$id;Tier=$r.Tier;Title=$r.Title;Mount=$r.Mount}
        }
        $after=Get-ArenaTitleValue -KnownTitles $c.knownTitles -AddBits $bits -ExpireTemporary
        $chosen=[uint32]$c.chosenTitle
        # Player::HasTitle(uint32) and login loading use the BIT INDEX here,
        # unlike title IDs in the reward manifest. Clear only a now-unowned
        # temporary title; retain unrelated and permanent selections.
        if($chosen -in @(29,30,31,32)){
            $chosenBit=[int]$chosen
            $words=$after.Trim().Split(' ')
            if(([uint64]$words[[int][Math]::Floor($chosenBit/32)] -band ([uint64]1 -shl ($chosenBit%32))) -eq 0){$chosen=0}
        }
        if($after -cne [string]$c.knownTitles -or $chosen -ne [uint32]$c.chosenTitle){
            $changes += [pscustomobject]@{Guid=$id;BeforeTitles=[string]$c.knownTitles;AfterTitles=$after;BeforeChosen=[uint32]$c.chosenTitle;AfterChosen=$chosen}
        }
    }
    [pscustomobject]@{Format=1;Season=$Season;Characters=$changes;Rewards=$rewards;CurrencyPolicy='Preserve';CreatedUtc=[DateTime]::UtcNow.ToString('o')}
}

function ConvertTo-SqlUtf8 {
    param([AllowEmptyString()][string]$Value)
    $hex=([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-','')
    if($hex.Length -eq 0){return "''"}
    return "CONVERT(0x$hex USING utf8)"
}

function Get-ArenaEngineSchemaSql {
    # Separate, named tables: never overwrite pre-existing core tables.
    return @'
CREATE TABLE IF NOT EXISTS codex_arena_settlement_v1 (
 season TINYINT UNSIGNED NOT NULL PRIMARY KEY,
 operation_id CHAR(36) NOT NULL UNIQUE,
 status VARCHAR(12) NOT NULL,
 created_utc DATETIME NOT NULL,
 plan_hash CHAR(64) NOT NULL
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS codex_arena_titles_v1 (
 season TINYINT UNSIGNED NOT NULL,
 guid INT UNSIGNED NOT NULL,
 before_titles TEXT NOT NULL,
 after_titles TEXT NOT NULL,
 before_chosen INT UNSIGNED NOT NULL,
 after_chosen INT UNSIGNED NOT NULL,
 PRIMARY KEY(season,guid)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS codex_arena_awards_v1 (
 season TINYINT UNSIGNED NOT NULL,
 guid INT UNSIGNED NOT NULL,
 title_id INT UNSIGNED NOT NULL,
 mount_id INT UNSIGNED NOT NULL,
 mail_id INT UNSIGNED NOT NULL,
 item_guid INT UNSIGNED NOT NULL,
 PRIMARY KEY(season,guid)
) ENGINE=InnoDB;
'@
}

function New-ArenaSettlementSql {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][guid]$OperationId,
          [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$PlanHash,
          [ValidateRange(0,2147480000)][long]$MaxMailId,[ValidateRange(0,2147480000)][long]$MaxItemGuid,
          [switch]$InjectFailure)
    if($Plan.Format -ne 1 -or $Plan.Season -notin @(1,2,3) -or $Plan.CurrencyPolicy -ne 'Preserve'){throw 'Invalid plan.'}
    $s=[int]$Plan.Season;$b=[Text.StringBuilder]::new()
    [void]$b.AppendLine('CREATE TEMPORARY TABLE codex_assert (id INT PRIMARY KEY) ENGINE=InnoDB; INSERT INTO codex_assert VALUES (1); START TRANSACTION;')
    [void]$b.AppendLine("INSERT INTO codex_arena_settlement_v1 VALUES ($s,'$OperationId','Settled',UTC_TIMESTAMP(),'$PlanHash');")
    # All assertions cause a duplicate-key error; mysql must abort on first
    # error and close the connection, rolling back the entire transaction.
    [void]$b.AppendLine("INSERT INTO codex_assert SELECT 1 WHERE (SELECT COALESCE(MAX(id),0) FROM mail)<>$MaxMailId OR (SELECT COALESCE(MAX(guid),0) FROM item_instance)<>$MaxItemGuid;")
    foreach($c in $Plan.Characters){
        $id=[uint32]$c.Guid;$before=ConvertTo-SqlUtf8 $c.BeforeTitles;$after=ConvertTo-SqlUtf8 $c.AfterTitles
        $bc=[uint32]$c.BeforeChosen;$ac=[uint32]$c.AfterChosen
        [void]$b.AppendLine("INSERT INTO codex_assert SELECT 1 WHERE (SELECT COUNT(*) FROM characters WHERE guid=$id AND BINARY knownTitles=BINARY $before AND chosenTitle=$bc)<>1;")
        [void]$b.AppendLine("INSERT INTO codex_arena_titles_v1 VALUES ($s,$id,$before,$after,$bc,$ac);")
        [void]$b.AppendLine("UPDATE characters SET knownTitles=$after,chosenTitle=$ac WHERE guid=$id;")
    }
    foreach($r in $Plan.Rewards){
        $id=[uint32]$r.Guid;$title=[uint32]$r.Title;$mount=[uint32]$r.Mount;$mail=0;$item=0
        $expected=Get-ArenaReward -Season $s -Tier $r.Tier
        if($title -ne $expected.Title -or $mount -ne $expected.Mount){throw 'Reward does not match its season/tier.'}
        [void]$b.AppendLine("INSERT INTO codex_assert SELECT 1 WHERE (SELECT COUNT(*) FROM characters WHERE guid=$id)<>1;")
        if($mount){
            $MaxMailId++;$MaxItemGuid++;$mail=$MaxMailId;$item=$MaxItemGuid
            if($mail -gt 2147483647 -or $item -gt 2147483647){throw 'GUID exhaustion.'}
            # Exact serialization verified against items created by this binary:
            # five spell charges and eleven enchantment slots (33 values).
            $ench=('0 '*33);$subject=ConvertTo-SqlUtf8 "竞技场 S$s 赛季奖励"
            [void]$b.AppendLine("INSERT INTO item_instance (guid,owner_guid,itemEntry,count,duration,charges,flags,enchantments,randomPropertyId,durability,itemTextId) VALUES ($item,0,$mount,1,0,'0 0 0 0 0 ',0,'$ench',0,0,0);")
            [void]$b.AppendLine("INSERT INTO mail (id,messageType,stationery,sender,receiver,subject,itemTextId,has_items,expire_time,deliver_time,money,cod,checked) VALUES ($mail,0,41,0,$id,$subject,0,1,UNIX_TIMESTAMP()+2592000,UNIX_TIMESTAMP(),0,0,0);")
            [void]$b.AppendLine("INSERT INTO mail_items VALUES ($mail,$item,$mount,$id);")
        }
        [void]$b.AppendLine("INSERT INTO codex_arena_awards_v1 VALUES ($s,$id,$title,$mount,$mail,$item);")
    }
    if($InjectFailure){[void]$b.AppendLine('INSERT INTO codex_assert VALUES (1); -- deliberate transaction failure test')}
    [void]$b.AppendLine('COMMIT;')
    $b.ToString()
}

function New-ArenaUndoSql {
    param([ValidateRange(1,3)][int]$Season,[Parameter(Mandatory)][guid]$OperationId)
    # Caller MUST first verify full post-operation fingerprint and offline state.
    # These SQL checks provide extra protection, not a substitute for that guard.
    return @"
CREATE TEMPORARY TABLE codex_assert (id INT PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO codex_assert VALUES (1);
START TRANSACTION;
INSERT INTO codex_assert SELECT 1 WHERE (SELECT COUNT(*) FROM codex_arena_settlement_v1 WHERE season=$Season AND operation_id='$OperationId' AND status='Settled')<>1;
INSERT INTO codex_assert SELECT 1 WHERE EXISTS (
 SELECT 1 FROM codex_arena_titles_v1 b LEFT JOIN characters c ON c.guid=b.guid
 WHERE b.season=$Season AND (c.guid IS NULL OR BINARY c.knownTitles<>BINARY b.after_titles OR c.chosenTitle<>b.after_chosen));
INSERT INTO codex_assert SELECT 1 WHERE EXISTS (
 SELECT 1 FROM codex_arena_awards_v1 a
 LEFT JOIN mail m ON m.id=a.mail_id
 LEFT JOIN mail_items mi ON mi.mail_id=a.mail_id AND mi.item_guid=a.item_guid
 LEFT JOIN item_instance i ON i.guid=a.item_guid
 WHERE a.season=$Season AND a.mount_id>0 AND
 (m.id IS NULL OR m.receiver<>a.guid OR m.checked<>0 OR m.has_items<>1 OR m.money<>0 OR m.cod<>0 OR
 mi.item_guid IS NULL OR mi.item_template<>a.mount_id OR mi.receiver<>a.guid OR
 i.guid IS NULL OR i.itemEntry<>a.mount_id OR i.owner_guid<>0 OR i.count<>1));
DELETE mi FROM mail_items mi JOIN codex_arena_awards_v1 a ON mi.mail_id=a.mail_id AND mi.item_guid=a.item_guid WHERE a.season=$Season AND a.mount_id>0;
DELETE m FROM mail m JOIN codex_arena_awards_v1 a ON m.id=a.mail_id WHERE a.season=$Season AND a.mount_id>0;
DELETE i FROM item_instance i JOIN codex_arena_awards_v1 a ON i.guid=a.item_guid WHERE a.season=$Season AND a.mount_id>0;
UPDATE characters c JOIN codex_arena_titles_v1 b ON b.guid=c.guid SET c.knownTitles=b.before_titles,c.chosenTitle=b.before_chosen WHERE b.season=$Season;
UPDATE codex_arena_settlement_v1 SET status='Undone' WHERE season=$Season AND operation_id='$OperationId';
COMMIT;
"@
}

Export-ModuleMember -Function Get-ArenaReward,Get-ArenaTitleValue,New-ArenaRewardPlan,Get-ArenaEngineSchemaSql,New-ArenaSettlementSql,New-ArenaUndoSql
