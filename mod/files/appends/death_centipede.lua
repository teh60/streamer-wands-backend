local default_death = death
death = function()
    GameAddFlagRun("miniboss_centipede")
    default_death()
end
