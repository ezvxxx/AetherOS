//! ext2 driver for 1-4 KiB blocks, directory entries, regular files,
//! directories, and direct through double-indirect block addressing.
const std = @import("std");
const ata = @import("../drivers/ata.zig");
pub const Entry = struct { name: [255]u8 = @splat(0), name_len: u8 = 0, size: u64 = 0, first_cluster: u32 = 0, attributes: u8 = 0 };
const Block = [4096]u8;
var mounted = false;
var device: u8 = 0;
var blocks: u32 = 0;
var inodes: u32 = 0;
var free_blocks: u32 = 0;
var free_inodes: u32 = 0;
var blocks_per_group: u32 = 0;
var inodes_per_group: u32 = 0;
var inode_size: u16 = 128;
var block_bitmap: u32 = 0;
var inode_bitmap: u32 = 0;
var inode_table: u32 = 0;
var block_size: u32 = 1024;
var partition_lba: u32 = 0;
var first_data_block: u32 = 1;
var has_filetype = false;
pub var last_write_error: u8 = 0;
pub var last_write_block: u32 = 0;

fn get16(b: []const u8, o: usize) u16 { return @as(u16,b[o]) | (@as(u16,b[o+1])<<8); }
fn get32(b: []const u8, o: usize) u32 { return @as(u32,b[o]) | (@as(u32,b[o+1])<<8) | (@as(u32,b[o+2])<<16) | (@as(u32,b[o+3])<<24); }
fn put16(b: []u8, o: usize, v: u16) void { b[o]=@truncate(v); b[o+1]=@truncate(v>>8); }
fn put32(b: []u8, o: usize, v: u32) void { b[o]=@truncate(v); b[o+1]=@truncate(v>>8); b[o+2]=@truncate(v>>16); b[o+3]=@truncate(v>>24); }
fn adjustGroupCounts(block_delta: i32, inode_delta: i32) void {
    const gd_block: u32 = if (block_size == 1024) 2 else 1;
    var gd: Block = undefined; if (!readBlock(gd_block, &gd)) return;
    put16(&gd, 12, @intCast(@as(i32, get16(&gd, 12)) + block_delta));
    put16(&gd, 14, @intCast(@as(i32, get16(&gd, 14)) + inode_delta));
    _ = writeBlock(gd_block, &gd);
}
fn readBlock(block: u32, out: *Block) bool {
    if (block >= blocks) return false;
    var sector: [512]u8 = undefined;
    var offset: usize = 0;
    while (offset < block_size) : (offset += 512) {
        if (!ata.readSector(device, partition_lba + block * (block_size / 512) + @as(u32, @intCast(offset / 512)), &sector)) return false;
        @memcpy(out[offset..][0..512], &sector);
    }
    return true;
}
fn writeBlock(block: u32, data: *const Block) bool {
    if (block >= blocks) return false;
    var sector: [512]u8 = undefined;
    var offset: usize = 0;
    while (offset < block_size) : (offset += 512) {
        @memcpy(&sector, data[offset..][0..512]);
        if (!ata.writeSector(device, partition_lba + block * (block_size / 512) + @as(u32, @intCast(offset / 512)), &sector)) return false;
    }
    return true;
}
pub fn isMounted() bool { return mounted; }
pub fn mount() bool { for (0..3) |d| if (mountDevice(@intCast(d))) return true; return false; }
pub fn mountDevice(d: u8) bool {
    mounted=false; partition_lba=0; if (d>2) return false;
    var first: [1024]u8 = undefined;
    if (!ata.readSector(d, 2, first[0..512]) or !ata.readSector(d, 3, first[512..1024])) return false;
    if (get16(&first, 56) != 0xef53) {
        var mbr: [512]u8 = undefined;
        if (!ata.readSector(d, 0, &mbr) or mbr[510] != 0x55 or mbr[511] != 0xaa) return false;
        var found = false;
        for (0..4) |part| {
            const off = 446 + part * 16;
            if (mbr[off + 4] != 0x83) continue;
            partition_lba = get32(&mbr, off + 8);
            if (partition_lba == 0 or !ata.readSector(d, partition_lba + 2, first[0..512]) or !ata.readSector(d, partition_lba + 3, first[512..1024])) continue;
            if (get16(&first, 56) == 0xef53) { found = true; break; }
        }
        if (!found) return false;
    } else partition_lba = 0;
    const log = get32(&first, 24);
    if (log > 2) return false;
    block_size = @as(u32, 1024) << @intCast(log);
    blocks = get32(&first, 4); inodes = get32(&first, 0); free_blocks = get32(&first, 12); free_inodes = get32(&first, 16); first_data_block = get32(&first, 20);
    has_filetype = (get32(&first, 96) & 2) != 0;
    blocks_per_group = get32(&first, 32); inodes_per_group = get32(&first, 40); inode_size = if (get16(&first, 88) >= 128) get16(&first, 88) else 128;
    if (blocks < 32 or blocks_per_group == 0 or inodes_per_group == 0 or inode_size > 256 or blocks_per_group > block_size * 8) return false;
    device = d; mounted = true;
    var gd: Block = undefined;
    const gd_block: u32 = if (block_size == 1024) 2 else 1;
    if (!readBlock(gd_block, &gd)) { mounted = false; return false; }
    block_bitmap = get32(&gd, 0); inode_bitmap = get32(&gd, 4); inode_table = get32(&gd, 8);
    return true;
}
pub fn rootCluster() u32 { return 2; }
fn inode(inum: u32, out: *[256]u8) bool {
    if (!mounted or inum==0 or inum>inodes) return false;
    const group=(inum-1)/inodes_per_group; const idx=(inum-1)%inodes_per_group;
    if (group!=0) return false;
    var b: Block=undefined; if (!readBlock(inode_table+(idx*@as(u32,inode_size))/block_size,&b)) return false;
    const off: usize=@intCast((idx*@as(u32,inode_size))%block_size);
    @memset(out,0); @memcpy(out[0..inode_size],b[off..][0..inode_size]); return true;
}
fn saveInode(inum:u32, data:*const [256]u8) bool {
    if (!mounted or inum==0 or (inum-1)/inodes_per_group!=0) return false;
    const idx=(inum-1)%inodes_per_group; var b:Block=undefined;
    if (!readBlock(inode_table+(idx*@as(u32,inode_size))/block_size,&b)) return false;
    const off:usize=@intCast((idx*@as(u32,inode_size))%block_size); @memcpy(b[off..][0..inode_size],data[0..inode_size]);
    return writeBlock(inode_table+(idx*@as(u32,inode_size))/block_size,&b);
}
fn dataBlock(ino:*const [256]u8, logical:u32) ?u32 {
    if (logical<12) { const n=get32(ino,40+@as(usize,logical)*4); return if(n==0)null else n; }
    const ptrs=block_size/4;
    if(logical<12+ptrs){const indirect=get32(ino,88);if(indirect==0)return null;var b:Block=undefined;if(!readBlock(indirect,&b))return null;const n=get32(&b,@as(usize,logical-12)*4);return if(n==0)null else n;}
    if(logical>=12+ptrs+ptrs*ptrs)return null;
    const double=get32(ino,92);if(double==0)return null;var first:Block=undefined;if(!readBlock(double,&first))return null;
    const rel=logical-12-ptrs;const leaf=get32(&first,@as(usize,rel/ptrs)*4);if(leaf==0)return null;var second:Block=undefined;if(!readBlock(leaf,&second))return null;const n=get32(&second,@as(usize,rel%ptrs)*4);return if(n==0)null else n;
}
fn setDataBlock(ino: *[256]u8, logical: u32, value: u32) bool {
    if (logical < 12) { put32(ino, 40 + @as(usize, logical) * 4, value); return true; }
    const ptrs = block_size / 4;
    if (logical < 12 + ptrs) {
        var table = get32(ino, 88);
        if (table == 0) { table = allocBlock() orelse return false; put32(ino, 88, table); put32(ino, 28, get32(ino, 28) + block_size / 512); const zero: Block = @splat(0); if (!writeBlock(table, &zero)) return false; }
        var b: Block = undefined; if (!readBlock(table, &b)) return false; put32(&b, @as(usize, logical - 12) * 4, value); return writeBlock(table, &b);
    }
    if (logical >= 12 + ptrs + ptrs * ptrs) return false;
    var double = get32(ino, 92);
    if (double == 0) { double = allocBlock() orelse return false; put32(ino, 92, double); put32(ino, 28, get32(ino, 28) + block_size / 512); const zero: Block = @splat(0); if (!writeBlock(double, &zero)) return false; }
    var first: Block = undefined; if (!readBlock(double, &first)) return false;
    const rel = logical - 12 - ptrs; const leaf_index = rel / ptrs;
    var leaf = get32(&first, @as(usize, leaf_index) * 4);
    if (leaf == 0) { leaf = allocBlock() orelse return false; put32(&first, @as(usize, leaf_index) * 4, leaf); if (!writeBlock(double, &first)) return false; put32(ino, 28, get32(ino, 28) + block_size / 512); const zero: Block = @splat(0); if (!writeBlock(leaf, &zero)) return false; }
    var second: Block = undefined; if (!readBlock(leaf, &second)) return false; put32(&second, @as(usize, rel % ptrs) * 4, value); return writeBlock(leaf, &second);
}
fn allocBlock() ?u32 {
    if(free_blocks==0)return null; var map:Block=undefined; if(!readBlock(block_bitmap,&map))return null;
    for(0..block_size*8) |bit| { const block=first_data_block+@as(u32,@intCast(bit)); if(block>=blocks)break; const m=@as(u8,1)<<@as(u3,@intCast(bit%8)); if((map[bit/8]&m)==0) {
        map[bit/8]|=m; if(!writeBlock(block_bitmap,&map))return null; free_blocks-=1; adjustGroupCounts(-1, 0);
        var sb:Block=undefined;const sb_block:u32=if(block_size==1024)1 else 0;const sb_off:usize=if(block_size==1024)0 else 1024;if(readBlock(sb_block,&sb)){put32(&sb,sb_off+12,free_blocks);_=writeBlock(sb_block,&sb);}return block;
    }} return null;
}
fn allocInode() ?u32 {
    if(free_inodes==0)return null; var map:Block=undefined; if(!readBlock(inode_bitmap,&map))return null;
    for(0..block_size*8) |bit| { if(bit>=inodes)break; const m=@as(u8,1)<<@as(u3,@intCast(bit%8)); if((map[bit/8]&m)==0) {
        map[bit/8]|=m; if(!writeBlock(inode_bitmap,&map))return null; free_inodes-=1; adjustGroupCounts(0, -1);
        var sb:Block=undefined;const sb_block:u32=if(block_size==1024)1 else 0;const sb_off:usize=if(block_size==1024)0 else 1024;if(readBlock(sb_block,&sb)){put32(&sb,sb_off+16,free_inodes);_=writeBlock(sb_block,&sb);}return @intCast(bit+1);
    }} return null;
}
fn find(parent:u32,name:[]const u8) ?u32 {
    var ino:[256]u8=undefined; if(!inode(parent,&ino))return null; const size=get32(&ino,4); var pos:u32=0;
    while(pos<size){const blk=dataBlock(&ino,pos/block_size) orelse return null; var b:Block=undefined;if(!readBlock(blk,&b))return null;
        var off:usize=@intCast(pos%block_size); while(off+8<=block_size and pos<size){const nlen=b[off+6];const rec=get16(&b,off+4); if(rec<8 or off+rec>block_size)return null;
            if(nlen>0 and nlen<=rec-8 and nlen==name.len and stdEql(b[off+8..][0..nlen],name))return get32(&b,off);
            off+=rec; pos+=rec; if(off==block_size)break;
        }
    } return null;
}
fn stdEql(a:[]const u8,b:[]const u8)bool { if(a.len!=b.len)return false; for(a,b)|x,y|if(x!=y)return false; return true; }
fn nameBytes(entry:*Entry, name:[]const u8) void { const n=@min(name.len,64); @memcpy(entry.name[0..n],name[0..n]); entry.name_len=@intCast(n); }
pub fn listDirectory(dir:u32,out:[]Entry)usize {
    var ino:[256]u8=undefined;if(!inode(dir,&ino))return 0;const size=get32(&ino,4);var pos:u32=0;var count:usize=0;
    while(pos<size and count<out.len){const blk=dataBlock(&ino,pos/block_size) orelse break;var b:Block=undefined;if(!readBlock(blk,&b))break;var off:usize=@intCast(pos%block_size);
        while(off+8<=block_size and pos<size and count<out.len){const rec=get16(&b,off+4);const nl:u8=if(has_filetype)b[off+6] else @truncate(get16(&b,off+6));const typ:u8=if(has_filetype)b[off+7] else 0;if(rec<8 or off+rec>block_size) return count;
            if(get32(&b,off)!=0 and nl>0 and nl<=rec-8 and !(nl==1 and b[off+8]=='.') and !(nl==2 and b[off+8]=='.' and b[off+9]=='.')){
                var child:[256]u8=undefined;const childno=get32(&b,off);if(inode(childno,&child)){out[count]=.{.first_cluster=childno,.size=get32(&child,4),.attributes=if(typ==2)0x10 else if(typ==7)0x10 else 0};nameBytes(&out[count],b[off+8..][0..nl]);count+=1;}}
            off+=rec;pos+=rec;if(off==block_size)break;
        }
    } return count;
}
pub fn listRoot(out:[]Entry)usize{return listDirectory(2,out);}
pub fn readFile(name:[]const u8,out:[]u8)?usize{return readFileAt(2,name,out);}
pub fn readFileAt(dir:u32,name:[]const u8,out:[]u8)?usize {
    const ino_no=find(dir,name) orelse return null;var ino:[256]u8=undefined;if(!inode(ino_no,&ino))return null;
    const size=get32(&ino,4);if(size>out.len)return null;var copied:usize=0;
    while(copied<size){const blk=dataBlock(&ino,@intCast(copied/block_size)) orelse return null;var b:Block=undefined;if(!readBlock(blk,&b))return null;const n=@min(block_size,size-copied);@memcpy(out[copied..][0..n],b[0..n]);copied+=n;}return size;
}
fn abortWrite(inum: u32, ino: *[256]u8, is_new: bool) bool {
    if (is_new) {
        _ = releaseInode(inum, ino);
    } else if (releaseDataBlocks(ino)) {
        _ = saveInode(inum, ino);
    }
    return false;
}
fn appendEntry(parent:u32,name:[]const u8,child:u32,kind:u8)bool {
    if(name.len==0 or name.len>255 or find(parent,name)!=null)return false;var p:[256]u8=undefined;if(!inode(parent,&p))return false;
    const need:usize=(8+name.len+3)&~@as(usize,3);const size=get32(&p,4);var pos:u32=0;
    while(pos<size){const bi=pos/block_size;const blk=dataBlock(&p,bi) orelse break;var b:Block=undefined;if(!readBlock(blk,&b))return false;var off:usize=@intCast(pos%block_size);
        while(off+8<=block_size){const rec=get16(&b,off+4);if(rec<8 or off+rec>block_size)return false;const existing_need=(8+b[off+6]+3)&~@as(usize,3);
            if(get32(&b,off)==0 and rec>=need or rec>=existing_need+need){const available:usize=if(get32(&b,off)==0)rec else rec-existing_need;const dest=if(get32(&b,off)==0)off else off+existing_need;const slot=@min(available,block_size-dest);if(slot<need)break;
                if(get32(&b,off)!=0)put16(&b,off+4,@intCast(existing_need));put32(&b,dest,child);put16(&b,dest+4,@intCast(slot));b[dest+6]=@intCast(name.len);b[dest+7]=kind;@memcpy(b[dest+8..][0..name.len],name);return writeBlock(blk,&b);}
            off+=rec;pos+=rec;if(off==block_size)break;
        }
    }
    const bi=(size+block_size-1)/block_size;const blk=dataBlock(&p,bi) orelse allocBlock() orelse return false;
    if(bi>=12+block_size/4)return false;if(bi>=12){var ptr=get32(&p,88);if(ptr==0){ptr=allocBlock() orelse return false;put32(&p,88,ptr);put32(&p,28,get32(&p,28)+block_size/512);if(!saveInode(parent,&p))return false;}var ib:Block=undefined;if(!readBlock(ptr,&ib))return false;put32(&ib,@as(usize,bi-12)*4,blk);if(!writeBlock(ptr,&ib))return false;}else put32(&p,40+@as(usize,bi)*4,blk);
    var b:Block=@splat(0);put32(&b,0,child);put16(&b,4,@intCast(block_size));b[6]=@intCast(name.len);b[7]=kind;@memcpy(b[8..][0..name.len],name);if(!writeBlock(blk,&b))return false;
    put32(&p,4,(bi+1)*block_size);put32(&p,28,get32(&p,28)+block_size/512);return saveInode(parent,&p);
}
pub fn writeFile(name:[]const u8,data:[]const u8)bool{return writeFileAt(2,name,data);}
pub fn writeFileAt(dir:u32,name:[]const u8,data:[]const u8)bool {
    last_write_error = 0; last_write_block = 0;
    const ptrs=block_size/4;
    const max_blocks: u64 = 12 + ptrs + @as(u64, ptrs) * ptrs;
    const max_bytes = max_blocks * block_size;
    if(name.len==0 or name.len>255 or data.len>std.math.maxInt(u32) or data.len>max_bytes)return false;
    const existing = find(dir, name);
    const no = existing orelse allocInode() orelse return false;
    var ino:[256]u8=undefined;
    if (existing == null) {
        @memset(&ino,0);put16(&ino,0,0x81a4);put16(&ino,26,1);
        if (!saveInode(no, &ino)) { last_write_error = 4; return abortWrite(no, &ino, true); }
    } else {
        if (!inode(no, &ino) or (get16(&ino, 0) & 0xf000) != 0x8000) { last_write_error = 4; return false; }
        if (!releaseDataBlocks(&ino) or !saveInode(no, &ino)) { last_write_error = 4; return false; }
    }
    if(!inode(no,&ino))return false;const needed=(data.len+block_size-1)/block_size;if(needed>12+block_size/4+block_size/4*block_size/4)return abortWrite(no, &ino, existing == null);
    for(0..needed)|i|{const logical:u32=@intCast(i);const prior=dataBlock(&ino,logical);const blk=prior orelse allocBlock() orelse { last_write_error=1;last_write_block=logical;return abortWrite(no, &ino, existing == null); };if(prior==null and !setDataBlock(&ino,logical,blk)){last_write_error=2;last_write_block=logical;_=freeBlock(blk);return abortWrite(no, &ino, existing == null);}
        var b:Block=@splat(0);const start=i*block_size;const n=@min(block_size,data.len-start);@memcpy(b[0..n],data[start..][0..n]);if(!writeBlock(blk,&b)){last_write_error=3;last_write_block=logical;return abortWrite(no, &ino, existing == null);}}
    put32(&ino,4,@intCast(data.len));put32(&ino,28,get32(&ino,28)+@as(u32,@intCast(needed*(block_size/512))));
    if (!saveInode(no, &ino)) { last_write_error=4;return abortWrite(no, &ino, existing == null); }
    if (existing == null and !appendEntry(dir, name, no, 1)) {
        last_write_error = 5;
        return abortWrite(no, &ino, true);
    }
    _ = ata.flushCache(device);
    return true;
}
pub fn makeDirectory(parent:u32,name:[]const u8)bool {
    if(name.len==0 or name.len>255 or find(parent,name)!=null)return false;const n=allocInode() orelse return false;const blk=allocBlock() orelse return false;
    var ino:[256]u8=@splat(0);put16(&ino,0,0x41ed);put32(&ino,4,block_size);put32(&ino,28,block_size/512);put32(&ino,40,blk);put16(&ino,26,2);if(!saveInode(n,&ino))return false;
    var b:Block=@splat(0);put32(&b,0,n);put16(&b,4,12);b[6]=1;b[7]=2;b[8]='.';put32(&b,12,parent);put16(&b,16,@intCast(block_size-12));b[18]=2;b[19]=2;b[20]='.';b[21]='.';if(!writeBlock(blk,&b))return false;
    if (!appendEntry(parent,name,n,2)) return false;
    var p: [256]u8 = undefined; if (inode(parent, &p)) { put16(&p, 26, get16(&p, 26) + 1); _ = saveInode(parent, &p); }
    _ = ata.flushCache(device);
    return true;
}
pub fn changeDirectory(parent:u32,name:[]const u8)?u32 {const n=find(parent,name) orelse return null;var ino:[256]u8=undefined;if(!inode(n,&ino) or (get16(&ino,0)&0xf000)!=0x4000)return null;return n;}
pub fn deleteFile(name:[]const u8)bool{return deleteFileAt(2,name);}
pub fn deleteFileAt(parent:u32,name:[]const u8)bool{return deleteEntryAt(parent,name);}
fn freeBlock(block: u32) bool {
    if (block < first_data_block) return false;
    const bit = block - first_data_block;
    if (bit >= block_size * 8) return false;
    var map: Block = undefined; if (!readBlock(block_bitmap, &map)) return false;
    const mask = @as(u8, 1) << @as(u3, @intCast(bit % 8));
    if ((map[bit / 8] & mask) == 0) return true;
    map[bit / 8] &= ~mask; if (!writeBlock(block_bitmap, &map)) return false; free_blocks += 1; adjustGroupCounts(1, 0);
    const sb_block: u32 = if (block_size == 1024) 1 else 0; const sb_off: usize = if (block_size == 1024) 0 else 1024;
    var sb: Block = undefined; if (readBlock(sb_block, &sb)) { put32(&sb, sb_off + 12, free_blocks); _ = writeBlock(sb_block, &sb); }
    return true;
}
fn releaseInode(inum: u32, ino: *const [256]u8) bool {
    var copy = ino.*;
    if (!releaseDataBlocks(&copy)) return false;
    put16(&copy, 26, 0); put32(&copy, 20, 0);
    if (!saveInode(inum, &copy)) return false;
    const bit = inum - 1; if (bit >= block_size * 8) return false;
    var bitmap: Block = undefined; if (!readBlock(inode_bitmap, &bitmap)) return false;
    bitmap[bit / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(bit % 8)));
    if (!writeBlock(inode_bitmap, &bitmap)) return false; free_inodes += 1; adjustGroupCounts(0, 1);
    const sb_block: u32 = if (block_size == 1024) 1 else 0; const sb_off: usize = if (block_size == 1024) 0 else 1024;
    var sb: Block = undefined; if (readBlock(sb_block, &sb)) { put32(&sb, sb_off + 16, free_inodes); _ = writeBlock(sb_block, &sb); }
    return true;
}
fn releaseDataBlocks(ino: *[256]u8) bool {
    for (0..12) |index| { const block = get32(ino, 40 + index * 4); if (block != 0 and !freeBlock(block)) return false; put32(ino, 40 + index * 4, 0); }
    const single = get32(ino, 88);
    if (single != 0) {
        var table: Block = undefined; if (!readBlock(single, &table)) return false;
        for (0..block_size / 4) |index| { const block = get32(&table, index * 4); if (block != 0 and !freeBlock(block)) return false; }
        if (!freeBlock(single)) return false; put32(ino, 88, 0);
    }
    const double = get32(ino, 92);
    if (double != 0) {
        var table: Block = undefined; if (!readBlock(double, &table)) return false;
        for (0..block_size / 4) |index| {
            const leaf = get32(&table, index * 4);
            if (leaf != 0) {
                var leaves: Block = undefined; if (!readBlock(leaf, &leaves)) return false;
                for (0..block_size / 4) |ptr_index| { const block = get32(&leaves, ptr_index * 4); if (block != 0 and !freeBlock(block)) return false; }
                if (!freeBlock(leaf)) return false;
            }
        }
        if (!freeBlock(double)) return false; put32(ino, 92, 0);
    }
    put32(ino, 4, 0); put32(ino, 28, 0);
    return true;
}
fn unlinkDirectoryReference(parent: u32, name: []const u8, expected_inode: u32) bool {
    var p: [256]u8 = undefined; if (!inode(parent, &p)) return false;
    const size = get32(&p, 4); var pos: u32 = 0;
    while (pos < size) {
        const blk = dataBlock(&p, pos / block_size) orelse return false; var b: Block = undefined; if (!readBlock(blk, &b)) return false;
        var off: usize = @intCast(pos % block_size);
        while (off + 8 <= block_size) {
            const rec = get16(&b, off + 4); const nl: u8 = if (has_filetype) b[off + 6] else @truncate(get16(&b, off + 6));
            if (rec < 8 or off + rec > block_size) return false;
            if (get32(&b, off) == expected_inode and nl == name.len and stdEql(b[off + 8 ..][0..nl], name)) { put32(&b, off, 0); return writeBlock(blk, &b); }
            off += rec; pos += rec; if (off == block_size) break;
        }
    }
    return false;
}
pub fn deleteEntryAt(parent:u32,name:[]const u8)bool {
    const no=find(parent,name) orelse return false;var target:[256]u8=undefined;if(!inode(no,&target))return false;
    if ((get16(&target, 0) & 0xf000) == 0x4000) {
        var children: [64]Entry = @splat(.{}); const child_count = listDirectory(no, &children);
        for (children[0..child_count]) |child| if (!deleteEntryAt(no, child.name[0..child.name_len])) return false;
    }
    if (!unlinkDirectoryReference(parent, name, no)) return false;
    if ((get16(&target, 0) & 0xf000) == 0x4000) {
        var p: [256]u8 = undefined;
        if (inode(parent, &p) and get16(&p, 26) > 0) { put16(&p, 26, get16(&p, 26) - 1); _ = saveInode(parent, &p); }
    }
    const released = releaseInode(no, &target);
    _ = ata.flushCache(device);
    return released;
}
pub fn renameAt(parent:u32,old:[]const u8,new:[]const u8)bool {const no=find(parent,old) orelse return false;var ino:[256]u8=undefined;if(!inode(no,&ino))return false;const typ:u8=if((get16(&ino,0)&0xf000)==0x4000)2 else 1;if(!appendEntry(parent,new,no,typ))return false;const renamed=unlinkDirectoryReference(parent,old,no);_=ata.flushCache(device);return renamed;}
