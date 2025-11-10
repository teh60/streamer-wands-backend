local ffi = require 'ffi'

ffi.cdef [[
    void* GetModuleHandleA(char* lpModuleName);

    void* memchr(const void* ptr, int value, size_t num);

    int memcmp(const void* ptr1, const void* ptr2, size_t num);

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

---@class Section
--- @field offset number
--- @field len number

--- @type Section
local data
--- @type Section
local rdata

for i = 0, pe.NumberOfSections - 1 do
    local section = sections[i]
    local name = ffi.string(section.Name, 8)
    if name == '.data\0\0\0' then
        data = {
            offset = base + section.VirtualAddress,
            len = section.VirtualSize,
        }
    elseif name == '.rdata\0\0' then
        rdata = {
            offset = base + section.VirtualAddress,
            len = section.VirtualSize,
        }
    end
end

-- if nolla ever makes it 64-bit it would be so
-- worth breaking this I can't even describe
if not data or not rdata then
    error('Noita stopped being 32-bit PE?')
end

--- @param section Section
--- @param needle ffi.cdata* | string
--- @return number|nil
local function memfind(section, needle)
    local first_byte = ffi.cast('uint8_t*', needle)[0]
    local search_ptr = ffi.cast('uint8_t*', section.offset)
    local remaining = section.len

    local needle_len = type(needle) == 'string' and #needle or ffi.sizeof(needle)

    while remaining >= needle_len do
        -- Find first byte of pattern
        local found = ffi.C.memchr(search_ptr, first_byte, remaining - needle_len + 1)
        if found == nil then
            break
        end

        -- Check if full pattern matches
        if ffi.C.memcmp(found, needle, needle_len) == 0 then
            return tonumber(ffi.cast('size_t', found))
        end

        -- Move past this match and continue
        local advance = ffi.cast('uint8_t*', found) - search_ptr + 1
        search_ptr = search_ptr + advance
        remaining = remaining - advance
    end

    return nil
end

--- @param value number
--- @return ffi.cdata*
local function to_le_bytes(value)
    local bytes = ffi.new('unsigned char[4]')
    bytes[0] = bit.band(value, 0xFF)
    bytes[1] = bit.band(bit.rshift(value, 8), 0xFF)
    bytes[2] = bit.band(bit.rshift(value, 16), 0xFF)
    bytes[3] = bit.band(bit.rshift(value, 24), 0xFF)
    return bytes
end

-- function log(fmt, ...)
--     print_error(string.format('[engine locator] ' .. fmt .. '\n', ...))
-- end
local log = log or function(...) end

--- @param name string
--- @return number|nil
local function locate_vftable(name)
    -- first we find the part of the RTTI type descriptor that contains
    --  the type name that should not ever change I hope
    local in_desc = memfind(data, name)
    if not in_desc then
        log('did not string `%s` in .data', name)
        return
    end
    log('found string `%s` at 0x%08X', name, in_desc)
    -- offset back to get the descriptor pointer value
    --  and scan for the usage of that value, which should be in an RTTI locator thing
    local in_locator = memfind(rdata, to_le_bytes(in_desc - 8))
    if not in_locator then
        log('did not RTTI locator for `%s` in .rdata', name)
        return
    end
    log('found RTTI locator for `%s` at 0x%08X', name, in_locator)

    -- same thing but to find usages of the locator, the vftable meta pointer
    local vftable_meta_ptr = memfind(rdata, to_le_bytes(in_locator - 12))
    if not vftable_meta_ptr then
        log('did not find vftable meta pointer for `%s` in .rdata', name)
        return
    end

    -- which is right before the vftable
    local vftable = vftable_meta_ptr + 4

    log('found vftable for %s: 0x%08X', name, vftable)

    return vftable
end

--- @param name string
--- @return number|nil
local function locate_static_global(name)
    local vftable = locate_vftable(name)
    if not vftable then
        -- locator does the logs
        return
    end
    local vftable_bytes = to_le_bytes(vftable)
    -- which is at the beginning of the static global
    local addr = memfind(data, vftable_bytes)
    if not addr then
        log('did not find static global for `%s` in .data', name)
        return
    end
    log('found static global %s: 0x%08X', name, addr)
    return addr
end

--[[
  everything above is my universal vftable/static global locator code
   surely I will fix the "vendoring reusable noita modding lua bits turbo-bitrot"
   situation at some point :(
  -- necauqua
]] --

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

--[[
  now the above are memory layouts of MSVC++ STL std::string and std::map<std::string, int32_t>
   as laid out in Noita (do not look at their templates lmao)
   with a couple of functions implemented to actually get the data
]] --

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
GLOBAL_STATS = ffi.cast('GlobalStats*', locate_static_global('.?AVGlobalStats@@')) --[[ @as GlobalStats ]]

--- @param name string
--- @return number|nil
function get_kv_stat(name)
    return GLOBAL_STATS and GLOBAL_STATS.KEY_VALUE_STATS[name]
end

--- @return {[string]: number}
function get_kv_stats()
    return GLOBAL_STATS and cpp_map_to_table(GLOBAL_STATS.KEY_VALUE_STATS) or {}
end

--- @class Stats
---  @field endroom_wins number
---  @field altar_wins number
---  @field deaths number
---  @field streaks number
---  @field highest_streak number
--- @return Stats|nil
function get_stats()
    -- meh
    if not GLOBAL_STATS then
        return
    end
    return {
        workWins = get_kv_stat('progress_ending0') or 0,
        altarWins = get_kv_stat('progress_ending1') or 0,
        deaths = GLOBAL_STATS.global.death_count,
        currentStreak = GLOBAL_STATS.session.streaks,
        highestStreak = GLOBAL_STATS.highest.streaks,
    }
end
