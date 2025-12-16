local ffi = require 'ffi'
local bit = require 'bit'

--[[ section.lua from @noita-ts/ffi inlined: ]]--

---@class Section
--- @field name string
--- @field offset number
--- @field len number
local Section = {}

function Section.new(name, offset, len)
    return setmetatable({
        name = name,
        offset = offset,
        len = len,
    }, { __index = Section })
end

ffi.cdef [[
    void* memchr(const void* ptr, int value, size_t num);
    int memcmp(const void *buffer1, const void *buffer2, size_t count);
]]

--- @param condition boolean
--- @param message string
--- @param name string
--- @param depth number
local function check(condition, message, name, depth)
    if not condition then
        error(string.format('%s %s', name, message), depth)
    end
end

--- @param offset number
--- @param len number
--- @param needle ffi.cdata* | string
--- @param needle_len number
--- @param limit number
--- @param name string
--- @return number
local function memfind(offset, len, needle, needle_len, limit, name)
    local first_byte = ffi.cast('uint8_t*', needle)[0]
    local search_ptr = ffi.cast('uint8_t*', offset)
    local remaining = len
    local scanned = 0

    while remaining >= needle_len do
        check(scanned < limit, 'not found: scan cutoff limit reached', name, 2)

        -- Find first byte of pattern
        local found = ffi.C.memchr(search_ptr, first_byte, math.min(remaining - needle_len + 1, limit - scanned))
        if found == nil then
            break
        end

        -- Check if full pattern matches
        if ffi.C.memcmp(found, needle, needle_len) == 0 then
            return tonumber(ffi.cast('size_t', found)) --[[ @as number ]]
        end

        -- Move past this match and continue
        local advance = ffi.cast('uint8_t*', found) - search_ptr + 1
        search_ptr = search_ptr + advance
        remaining = remaining - advance
        scanned = scanned + advance
    end

    ---@diagnostic disable-next-line: missing-return -- ugh lmao
    check(false, 'not found: scanned the entire range', name, 2)
end

--- @param offset number
--- @param len number
--- @param needle ffi.cdata* | string
--- @param needle_len number
--- @param limit number
--- @param name string
--- @return number
local function memrfind(offset, len, needle, needle_len, limit, name)
    local first_byte = ffi.cast('uint8_t*', needle)[0]
    local search_ptr = ffi.cast('uint8_t*', offset)
    local end_ptr = search_ptr + len - needle_len
    local scanned = 0

    while end_ptr >= search_ptr do
        check(scanned < limit, 'not found: scan cutoff limit reached', name, 2)

        if end_ptr[0] == first_byte then
            if ffi.C.memcmp(end_ptr, needle, needle_len) == 0 then
                return tonumber(ffi.cast('size_t', end_ptr)) --[[ @as number ]]
            end
        end
        end_ptr = end_ptr - 1
        scanned = scanned + 1
    end

    ---@diagnostic disable-next-line: missing-return -- ugh lmao
    check(false, 'not found: scanned the entire range', name, 2)
end

---@class ScanParams
--- @field skip number?
--- @field at number?
--- @field back true?
--- @field limit number?
--- @field name string?

--- @param needle ffi.cdata* | number[] | number | string
--- @param params ScanParams?
--- @return number
function Section:scan(needle, params)
    params = params or {}
    local skip = params.skip or 0
    local back = params.back
    local at = params.at
    local limit = params.limit or 256
    local name = params.name or ('needle in ' .. self.name)

    -- if a sole number is given we assume its a 4-byte little-endian integer 🤷
    if type(needle) == 'number' then
        needle = ffi.new('char[4]', {
            bit.band(needle, 0xFF),
            bit.band(bit.rshift(needle, 8), 0xFF),
            bit.band(bit.rshift(needle, 16), 0xFF),
            bit.band(bit.rshift(needle, 24), 0xFF),
        })
    elseif type(needle) == 'table' or type(needle) == 'string' then
        needle = ffi.new('char[?]', #needle, needle)
    end

    local needle_len = ffi.sizeof(needle)
    check(needle_len and needle_len ~= 0 or false, 'invalid needle', name, 1)
    needle_len = needle_len --[[ @as integer ]] -- urgh

    if not back then
        local index = 0
        if at then
            index = at - self.offset
            check(index >= 0 and index <= self.len, 'not found: at parameter out of bounds', name, 1)
        end
        for _ = 0, skip do
            local found = memfind(self.offset + index, self.len - index, needle, needle_len, limit, name)
            index = found - self.offset + needle_len
        end
        return self.offset + index - needle_len
    end

    local index = self.len
    if at then
        index = at - self.offset
        check(index >= 0 and index <= self.len, 'not found: at parameter out of bounds', name, 1)
    end
    for _ = 0, skip do
        local found = memrfind(self.offset, index, needle, needle_len, limit, name)
        index = found - self.offset
    end
    return self.offset + index
end

--[[ index.lua from @noita-ts/ffi inlined: ]]--

--- @type Section
local data
--- @type Section
local rdata
--- @type Section
local text

ffi.cdef [[
    void* GetModuleHandleA(char* lpModuleName);

    bool VirtualProtect(void* adress, size_t size, int new_protect, int* old_protect);

    typedef struct {
        char pad[60];
        uint32_t e_lfanew;
    } IMAGE_DOS_HEADER;

    typedef struct {
        char pad[6];
        uint16_t NumberOfSections;
        char pad2[12];
        uint16_t SizeOfOptionalHeader;
        char pad3[2];
    } IMAGE_NT_HEADERS32;

    typedef struct {
        char Name[8];
        uint32_t VirtualSize;
        uint32_t VirtualAddress;
        char pad[24];
    } IMAGE_SECTION_HEADER;
]]

-- dont hardcode 0x00400000 because of ASLR
local base = tonumber(ffi.cast('uint32_t', ffi.C.GetModuleHandleA(nil)))

-- look at the PE header to figure out the exact ranges of .data and .rdata
-- sections to minimize the ranges we have to scan
-- (also avoids reading out-of-bounds memory if we dont find something)

--- @type { e_lfanew: number }
local dos = ffi.cast('IMAGE_DOS_HEADER*', base)
--- @type { SizeOfOptionalHeader: number; NumberOfSections : number }
local pe = ffi.cast('IMAGE_NT_HEADERS32*', base + dos.e_lfanew)
--- @type { [number]: { Name: any; VirtualAddress: number; VirtualSize: number } }
local sections = ffi.cast('IMAGE_SECTION_HEADER*', ffi.cast('char*', pe) + 24 + pe.SizeOfOptionalHeader)

for i = 0, pe.NumberOfSections - 1 do
    local section = sections[i]
    local name = ffi.string(section.Name, 8)
    if name == '.data\0\0\0' then
        data = Section.new(
            '.data',
            base + section.VirtualAddress,
            section.VirtualSize
        )
    elseif name == '.rdata\0\0' then
        rdata = Section.new(
            '.rdata',
            base + section.VirtualAddress,
            section.VirtualSize
        )
    elseif name == '.text\0\0\0' then
        text = Section.new(
            '.text',
            base + section.VirtualAddress,
            section.VirtualSize
        )
    end
end

-- if nolla ever makes it 64-bit it would be so
-- worth breaking this I can't even describe
if not data or not rdata or not text then
    error('Noita stopped being 32-bit PE?')
end

local M = {
    data = data,
    rdata = rdata,
    text = text,
}

--- @param str string
--- @return number
function M.locateString(str)
    -- just scan the entire .rdata
    return rdata:scan(str .. '\0', {
        name = string.format('string "%s" in .rdata', str),
        limit = rdata.len,
    })
end

--- @param str string
--- @return number
function M.locateStringPush(str)
    local addr = M.locateString(str)
    return text:scan({
        0x68, -- PUSH imm32
        bit.band(addr, 0xFF),
        bit.band(bit.rshift(addr, 8), 0xFF),
        bit.band(bit.rshift(addr, 16), 0xFF),
        bit.band(bit.rshift(addr, 24), 0xFF),
    }, {
        name = string.format('PUSH 0x%08X ("%s")', addr, str),
        limit = text.len,
    })
end

--- @param rtti_name string
--- @return number
function M.locateVftable(rtti_name)
    -- first we find the part of the RTTI type descriptor that contains
    --  the type name that should not ever change I hope
    local in_desc = data:scan(rtti_name, {
        name = string.format('string `%s` in .data', rtti_name),
        limit = data.len,
    })

    -- offset back to get the descriptor pointer value
    --  and scan for the usage of that value, which should be in an RTTI locator thing
    local in_locator = rdata:scan(in_desc - 8, {
        name = string.format('RTTI locator for `%s` (descriptor at 0x%08X)', rtti_name, in_desc - 8),
        limit = rdata.len,
    })

    -- same thing but to find usages of the locator, the vftable meta pointer
    local vftable_meta_ptr = rdata:scan(in_locator - 12, {
        name = string.format('vftable meta pointer for `%s` (locator at 0x%08X)', rtti_name, in_locator - 12),
        limit = rdata.len,
    })

    -- which is right before the vftable
    return vftable_meta_ptr + 4
end

--- @param rtti_name string
--- @return number
function M.locateStaticGlobal(rtti_name)
    local vftable = M.locateVftable(rtti_name)
    -- look for the reference to the vftable in .data,
    -- which is at the beginning of the static global
    return data:scan(vftable, {
        name = string.format('static global for `%s` (vftable at 0x%08X)', rtti_name, vftable),
        limit = data.len,
    })
end

-- see https://learn.microsoft.com/en-us/windows/win32/Memory/memory-protection-constants
local PAGE_EXECUTE_READ_WRITE = 0x40

---@param addr number
---@param patch ffi.cdata*|number[]|string
function M.patchRaw(addr, patch)
    local ptr = ffi.cast('void*', addr)

    if type(patch) == 'table' or type(patch) == 'string' then
        patch = ffi.new('char[?]', #patch, patch)
    end

    local restore_protection = ffi.new 'int[1]'
    local success = ffi.C.VirtualProtect(
        ptr, ffi.sizeof(patch), PAGE_EXECUTE_READ_WRITE, restore_protection
    )

    if not success then
        error("couldn't change memory protection")
    end

    ffi.copy(ptr, patch, ffi.sizeof(patch) --[[ @as number ]])

    -- restore protection
    ffi.C.VirtualProtect(
        ptr,
        ffi.sizeof(patch),
        restore_protection[0],
        restore_protection
    )
end

---@param needle ffi.cdata* | number[] | number | string
---@param params ScanParams?
function M.scan(needle, params)
    return text:scan(needle, params)
end

---@param needle ffi.cdata* | number[] | number | string
---@param patch ffi.cdata*|number[]|string
---@param params ScanParams?
function M.patch(needle, patch, params)
    M.patchRaw(text:scan(needle, params), patch)
end

--[[ end of @noita-ts/ffi inlines (for now) ]]--

--[[
  Memory layouts of MSVC++ STL std::string and std::map<std::string, int32_t>
  as laid out in Noita (do not look at their templates lmao) with a couple of
  functions implemented to actually get the data
]]--

ffi.cdef [[
    typedef struct cpp_string {
        union {
            char buf[16];
            char* ptr;
        };
        uint32_t len;
        uint32_t cap;
    } cpp_string;
]]

ffi.metatype('cpp_string', {
    __tostring = function(s)
        return ffi.string(s.cap <= 15 and s.buf or s.ptr, s.len)
    end,
    __len = function(s)
        return s.len
    end,
})

ffi.cdef [[
    typedef struct cpp_map_node {
        struct cpp_map_node* left;
        struct cpp_map_node* up;
        struct cpp_map_node* right;
        uint32_t _meta;
        cpp_string key;
        int32_t value;
    } cpp_map_node;

    typedef struct cpp_map {
        cpp_map_node* root;
        uint32_t len;
    } cpp_map;
]]

ffi.metatype('cpp_map', {
    __index = function(map, key)
        if not map.root or not map.root.up then
            return
        end
        local node = map.root.up
        while node ~= nil and node ~= map.root do
            local node_key = tostring(node.key)
            if key == node_key then
                return node.value
            elseif key < node_key then
                node = node.left
            else
                node = node.right
            end
        end
    end,
    __len = function(map)
        return map.len
    end,
})

---@return {[string]: number}
local function cpp_map_to_table(map)
    local result = {}
    if not map.root or not map.root.up then
        return result
    end
    local function traverse(node)
        if not node or node == map.root then
            return
        end
        traverse(node.left)
        result[tostring(node.key)] = node.value
        traverse(node.right)
    end
    traverse(map.root.up)
    return result
end

--[[ meh just copy over the entire GlobalStats definition ]]--

ffi.cdef [[
    typedef struct {
        void* vftable;
        bool dead;
        int32_t death_count;
        int32_t streaks;
        uint32_t world_seed;
        cpp_string killed_by;
        cpp_string killed_by_extra;
        struct { float x; float y; } death_pos;
        double playtime;
        cpp_string playtime_str;
        int32_t places_visited;
        int32_t enemies_killed;
        int32_t heart_containers;
        int64_t hp;
        int64_t gold;
        int64_t gold_all;
        bool gold_infinite;
        int32_t items;
        int32_t projectiles_shot;
        int32_t kicks;
        double damage_taken;
        double healed;
        int32_t teleports;
        int32_t wands_edited;
        int32_t biomes_visited_with_wands;
    } GameStats;

    typedef struct {
        void* vftable;
        int32_t STATS_VERSION;
        int32_t DEBUG_HOW_MANY_TIMES_DONE;
        bool DEBUG_IS_ON;
        int32_t DEBUG_HOW_MANY_RESETS;
        bool DEBUG_FIXED_STATS;
        bool session_dead;
        cpp_map KEY_VALUE_STATS;
        GameStats session;
        GameStats highest;
        GameStats global;
        GameStats prev_best;
    } GlobalStats;
]]

--- @class GameStats
---  @field death_count number
---  @field streaks number
--- @class GlobalStats
---  @field KEY_VALUE_STATS {[string]: number | nil}
---  @field global GameStats
---  @field session GameStats
---  @field highest GameStats
--- @type GlobalStats|nil
GLOBAL_STATS = ffi.cast('GlobalStats*', M.locateStaticGlobal('.?AVGlobalStats@@')) --[[ @as GlobalStats ]]

--- @param name string
--- @return number|nil
function get_kv_stat(name)
    return GLOBAL_STATS.KEY_VALUE_STATS[name]
end

--- @return {[string]: number}
function get_kv_stats()
    return cpp_map_to_table(GLOBAL_STATS.KEY_VALUE_STATS)
end

--- @class Stats
---  @field workWins number
---  @field altarWins number
---  @field deaths number
---  @field currentStreak number
---  @field highestStreak number
--- @return Stats|nil
function get_stats()
    return {
        workWins = get_kv_stat('progress_ending0') or 0,
        altarWins = get_kv_stat('progress_ending1') or 0,
        deaths = GLOBAL_STATS.global.death_count,
        currentStreak = GLOBAL_STATS.session.streaks,
        highestStreak = GLOBAL_STATS.highest.streaks,
    }
end

--[[ backported from negative-streak ]]--

function enable_streaks()
    local push = M.locateStringPush("$stat_streaks");

    -- make isVanilla always return true, so that the streaks are always counted and shown
    --  basically a subset of disable mod restrictions
    local isVanillaCall = M.scan({ 0xe8 }, { at = push, back = true });
    local isVanillaOffset = ffi.cast("int*", isVanillaCall + 1);
    local isVanillaAddr = isVanillaCall + 5 + isVanillaOffset[0];

    -- just patch the function to instantly return 1 lmao
    M.patchRaw(isVanillaAddr,
      {
        0xb0, -- \
        0x01, -- | mov al, 1
        0xc3, -- ret
      }
    );
end