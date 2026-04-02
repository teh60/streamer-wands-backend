local default_death = death
death = function(damage_type_bit_field, damage_message, entity_thats_responsible, drop_items)
    local tcount = tonumber(GlobalsGetValue("ULTIMATE_KILLER_KILLS", "0"))
    if (tcount >= 9) then
        GameAddFlagRun("miniboss_friend")
    end
    default_death(damage_type_bit_field, damage_message, entity_thats_responsible, drop_items)
end
