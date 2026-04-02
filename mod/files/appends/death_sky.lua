local default_death = death
death = function(damage_type_bit_field, damage_message, entity_thats_responsible, drop_items)
    GameAddFlagRun("miniboss_sky")
    default_death(damage_type_bit_field, damage_message, entity_thats_responsible, drop_items)
end
